defmodule Rnews1.PipelineTest do
  @moduledoc """
  The content pipeline and delivery, end to end, against a stubbed network:
  treg discovery, the publisher's page, OpenAI, Mailgun. The one guarantee
  worth re-proving in the port is that the publisher's text is read, written
  from, and never stored.
  """
  use Rnews1.DataCase, async: false
  alias Rnews1.{Editorial, Outbox, Stories, StoryPipeline, Topics, Worker}

  @article String.duplicate("Regulators in three countries opened a joint inquiry into the payments group after auditors flagged inconsistencies in its reserve reporting. ", 6)

  setup do
    Application.put_env(:rnews1, :req_options, plug: {Req.Test, Rnews1.HTTP})
    Rnews1.Cache.clear()
    on_exit(fn -> Application.delete_env(:rnews1, :req_options) end)
    :ok
  end

  defp rewrite_for(id) do
    %{"id" => id, "headline" => "Auditors' doubts prompt a three-nation inquiry", "standfirst" => "A payments firm's reserve figures are under scrutiny.",
      "body" => "Authorities in three jurisdictions are examining how a payments company accounted for the money it holds on behalf of customers.\n\nThe move follows an audit that questioned the firm's own numbers."}
  end

  defp stub_network(opts \\ []) do
    items = Keyword.get(opts, :items, [
      %{"url" => "https://publisher.test/a", "title" => "Payments group faces inquiry", "publishedDate" => "2026-09-10T08:00:00Z"},
      %{"url" => "https://www.rnews1.test/news/x/y", "title" => "Our own story", "publishedDate" => "2026-09-10T07:00:00Z"},
      %{"url" => "https://publisher.test/b", "title" => "A second story", "publishedDate" => "2026-09-10T06:00:00Z"}
    ])
    rewrites = Keyword.get(opts, :rewrites, &rewrite_for/1)
    robots = Keyword.get(opts, :robots, "User-agent: *\nAllow: /\n")

    Req.Test.stub(Rnews1.HTTP, fn conn ->
      case {conn.host, conn.request_path} do
        {"treg.to", _} ->
          Req.Test.json(conn, %{"results" => items})

        {"publisher.test", "/robots.txt"} ->
          Plug.Conn.send_resp(conn, 200, robots)

        {"publisher.test", _} ->
          body = ~s(<html><head><script type="application/ld+json">{"@type":"NewsArticle","articleBody":"#{@article}"}</script></head><body><p>x</p></body></html>)
          conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, body)

        {"api.openai.com", _} ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          request = Jason.decode!(raw)
          user = request["messages"] |> List.last() |> Map.get("content") |> Jason.decode!()

          content =
            cond do
              Map.has_key?(user, "articles") -> %{"stories" => Enum.map(user["articles"], &rewrites.(&1["id"]))}
              Map.has_key?(user, "article") -> rewrites.("article") |> Map.put("tags", ["payments", "audit"])
              Map.has_key?(user, "headline") -> %{"headline" => "Traducido: " <> user["headline"], "standfirst" => "T", "body" => "Cuerpo traducido"}
              true -> %{}
            end

          Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => Jason.encode!(content)}}]})

        {"api.mailgun.net", path} ->
          if String.ends_with?(path, "/messages"),
            do: Req.Test.json(conn, %{"id" => "<mg-id@mg.rnews1.test>"}),
            else: Req.Test.json(conn, %{"domain" => %{"state" => "active"}})

        other ->
          flunk("unexpected request #{inspect(other)}")
      end
    end)
  end

  describe "the newsletter pipeline" do
    test "reads three candidates, skips our own, writes the rest, and stores no source text" do
      stub_network()
      DB.execute("INSERT INTO topics(key, query, language) VALUES('t1','\"payments\"','en')")

      stories = StoryPipeline.build_issue(%{topic_key: "t1", query: "\"payments\"", language: "en", issue_date: "2026-09-10"})

      assert length(stories) == 2
      [first | _] = stories
      assert first.headline == "Auditors' doubts prompt a three-nation inquiry"
      assert first.extraction == "jsonld"
      assert first.source_chars > 400
      assert first.verbatim_run < 12
      refute Enum.any?(stories, &(&1.source_url =~ "rnews1.test"))

      # Nowhere in the row is the publisher's text. Not the body, not any column.
      row = DB.one("SELECT * FROM stories WHERE id = $1", [first.id])
      refute Enum.any?(Map.values(row), fn v -> is_binary(v) and String.contains?(v, "auditors flagged inconsistencies") end)
      refute row.body =~ "Regulators in three countries"

      # Running again on the same day adds nothing: the issue is already written.
      assert length(StoryPipeline.build_issue(%{topic_key: "t1", query: "\"payments\"", language: "en", issue_date: "2026-09-10"})) == 2
    end

    test "a rewrite that lifts the source falls back to the headline, marked as rejected" do
      stub_network(rewrites: fn id -> %{"id" => id, "headline" => "Inquiry", "standfirst" => "S", "body" => @article} end)
      DB.execute("INSERT INTO topics(key, query, language) VALUES('t1','\"payments\"','en')")
      [story | _] = StoryPipeline.build_issue(%{topic_key: "t1", query: "\"payments\"", language: "en", issue_date: "2026-09-10"})
      assert story.extraction == "rejected_verbatim"
      assert story.headline == "Payments group faces inquiry"
      assert story.verbatim_run >= 12
      refute story.body =~ "auditors flagged"
    end

    test "obeys robots.txt: a denied page is written from the headline only" do
      stub_network(robots: "User-agent: *\nDisallow: /\n")
      DB.execute("INSERT INTO topics(key, query, language) VALUES('t1','\"payments\"','en')")
      [story | _] = StoryPipeline.build_issue(%{topic_key: "t1", query: "\"payments\"", language: "en", issue_date: "2026-09-10"})
      assert story.extraction == "robots_denied"
      assert story.source_chars == 0
    end
  end

  describe "the journal" do
    test "publishes the source language and every translation asked for, under one slug" do
      stub_network()
      result = Editorial.write_for_category("Business", languages: ["es", "fr"], concurrency: 2)
      assert result.status == "published"
      assert result.languages == ["en", "es", "fr"]
      assert result.slug == "auditors-doubts-prompt-a-three-nation-inquiry"
      rows = DB.all("SELECT language, slug, translation_key, fingerprint, origin, to_char(issue_date,'YYYY-MM-DD') AS d FROM stories ORDER BY language")
      assert Enum.map(rows, & &1.language) == ["en", "es", "fr"]
      assert Enum.uniq(Enum.map(rows, & &1.d)) |> length() == 1
      assert Enum.all?(rows, &(&1.origin == "editorial" and &1.slug == result.slug))
      # Only the source-language row carries the fingerprint; translations are the same coverage.
      assert Enum.count(rows, & &1.fingerprint) == 1
      assert Stories.slug_taken?(publication().id, result.slug)

      # The same source is never covered twice.
      assert Editorial.write_for_category("Business", languages: []).status in ["nothing_fresh", "published"]
    end

    test "moves to the next publisher when a draft is too close, and reports when none work" do
      stub_network(rewrites: fn id -> %{"id" => id, "headline" => "Inquiry", "standfirst" => "S", "body" => @article} end)
      result = Editorial.write_for_category("Business", languages: [])
      assert result.status == "too_close_to_source"
      assert result.attempts == 2
      assert result.verbatim_run >= 12
      assert DB.value("SELECT count(*) FROM stories") == 0
    end
  end

  describe "delivery" do
    test "sends through Mailgun and records the provider id; failures back off or park" do
      stub_network()
      id = Outbox.enqueue(%{to_email: "a@b.test", kind: "login", payload: %{url: "https://rnews1.test/login/x"}})
      assert %{accepted: true} = Worker.deliver_one()
      job = DB.one("SELECT * FROM outbox WHERE id = $1", [id])
      assert job.status == "accepted" and job.provider_message_id == "<mg-id@mg.rnews1.test>"
      assert Worker.deliver_one() == nil

      Req.Test.stub(Rnews1.HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "busy") end)
      id2 = Outbox.enqueue(%{to_email: "c@d.test", kind: "login", payload: %{url: "u"}})
      assert %{retrying: true} = Worker.deliver_one()
      assert DB.value("SELECT status FROM outbox WHERE id = $1", [id2]) == "pending"

      Req.Test.stub(Rnews1.HTTP, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      DB.execute("UPDATE outbox SET run_after = now() WHERE id = $1", [id2])
      assert %{unknown: true} = Worker.deliver_one()
      assert DB.value("SELECT status FROM outbox WHERE id = $1", [id2]) == "unknown"
    end

    test "a suppressed recipient is never mailed; the queue refuses kinds it cannot build" do
      contact = DB.value("INSERT INTO contacts(email, opted_out_at) VALUES('gone@b.test', now()) RETURNING id")
      Outbox.enqueue(%{to_email: "gone@b.test", contact_id: contact, kind: "campaign", payload: %{}})
      assert %{suppressed: true} = Worker.deliver_one()
      assert_raise Postgrex.Error, ~r/outbox_kind_check/, fn -> Outbox.enqueue(%{to_email: "x@b.test", kind: "mystery", payload: %{}}) end
    end
  end

  describe "topic refresh" do
    test "puts the crawled items back on the topic row, and a failure in last_error" do
      stub_network()
      DB.execute("INSERT INTO topics(key, query, language, refresh_after) VALUES($1,$2,'en', now() - interval '1 minute')", ["t1", ~s("payments")])

      assert %{key: "t1"} = Worker.refresh_one_topic()

      row = DB.one("SELECT refreshed_at, last_error, refresh_after > now() AS held, jsonb_array_length(items) AS n FROM topics WHERE key = 't1'")
      assert row.refreshed_at, "the preview stays empty for ever if the write back does not land"
      assert row.n > 0
      assert row.held
      refute row.last_error
    end

    test "records the reason a refresh failed instead of losing it" do
      DB.execute("INSERT INTO topics(key, query, language) VALUES('t2','\"x\"','en')")

      Topics.record_failure("t2", "upstream said no")

      row = DB.one("SELECT last_error, refresh_after > now() AS held FROM topics WHERE key = 't2'")
      assert row.last_error == "upstream said no"
      assert row.held
    end
  end
end
