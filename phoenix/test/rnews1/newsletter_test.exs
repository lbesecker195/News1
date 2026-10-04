defmodule Rnews1.NewsletterTest do
  @moduledoc """
  Who gets each publication's daily edition, and how it is scheduled and built.
  """
  use Rnews1.DataCase, async: false
  alias Rnews1.{DB, Newsletter, Publications, Subscribers, Worker}

  @day "2026-09-10"
  @after_the_hour ~U[2026-09-10 14:00:00Z]

  setup do
    archive = publication()

    fashion =
      Publications.create(%{
        slug: "fashion",
        name: "FashionShowOn",
        hostname: "fashionshowon.rnews1.test",
        languages: ["en"],
        sections: [%{name: "Runway", query: "runway"}]
      })

    %{archive: archive, fashion: fashion}
  end

  defp story(pub, slug, headline, date \\ @day) do
    archive_story(%{
      publication_id: pub.id,
      slug: slug,
      translation_key: slug,
      category: "Runway",
      headline: headline,
      issue_date: date,
      published_at: ~U[2026-09-10 08:00:00Z]
    })
  end

  defp emails(pub), do: pub |> Newsletter.audience() |> Enum.map(&{&1.email, &1.reason})

  defp with_edition_hour(hour) do
    previous = Application.get_env(:rnews1, :env)
    Application.put_env(:rnews1, :env, Keyword.put(previous, :edition_hour, hour))
    on_exit(fn -> Application.put_env(:rnews1, :env, previous) end)
  end

  defp editions_queued,
    do:
      DB.all(
        "SELECT to_email, payload, dedupe_key FROM outbox WHERE kind = 'edition' ORDER BY to_email"
      )

  describe "subscribing" do
    test "takes the address as opted in: subscribed at once, nothing mailed to confirm it", %{
      fashion: fashion
    } do
      assert Newsletter.subscribe(fashion, "  Reader@Example.TEST ") == :ok

      assert emails(fashion) == [{"reader@example.test", :subscribed}]
      assert DB.value("SELECT count(*)::int FROM outbox") == 0
    end

    test "subscribing twice is one subscription", %{fashion: fashion} do
      assert Newsletter.subscribe(fashion, "reader@example.test") == :ok
      assert Newsletter.subscribe(fashion, "reader@example.test") == :ok

      assert DB.value("SELECT count(*)::int FROM newsletter_subscriptions") == 1
    end

    test "refuses only an address that is not one", %{fashion: fashion} do
      assert Newsletter.subscribe(fashion, "not an address") == {:error, :invalid_email}

      assert Newsletter.subscribe(fashion, String.duplicate("a", 250) <> "@x.test") ==
               {:error, :invalid_email}

      assert Newsletter.subscribe(fashion, nil) == {:error, :invalid_email}
      assert DB.value("SELECT count(*)::int FROM newsletter_subscriptions") == 0
    end

    test "an address that opted out stays out, and the form answers the same", %{fashion: fashion} do
      DB.execute(
        "INSERT INTO contacts(email, opted_out_at) VALUES('gone@example.test', now())",
        []
      )

      assert Newsletter.subscribe(fashion, "gone@example.test") == :ok
      assert DB.value("SELECT count(*)::int FROM newsletter_subscriptions") == 0
      assert emails(fashion) == []
    end

    test "opting out later, from any RNews1 email, takes the subscriber off", %{fashion: fashion} do
      Newsletter.subscribe(fashion, "reader@example.test")

      DB.execute(
        "UPDATE contacts SET opted_out_at = now() WHERE email = 'reader@example.test'",
        []
      )

      assert emails(fashion) == []
    end
  end

  describe "the audience" do
    test "a publication's subscribers get its edition; another publication's do not", %{
      archive: archive,
      fashion: fashion
    } do
      Newsletter.subscribe(fashion, "runway@example.test")
      Newsletter.subscribe(archive, "generalist@example.test")

      assert emails(fashion) == [{"runway@example.test", :subscribed}]
      assert {"generalist@example.test", :subscribed} in emails(archive)
      refute Enum.any?(emails(archive), fn {email, _} -> email == "runway@example.test" end)
    end

    test "business contacts get the archive's edition only, and are told why", %{
      archive: archive,
      fashion: fashion
    } do
      DB.execute("INSERT INTO contacts(email, source) VALUES('buyer@corp.test', 'import')", [])

      assert {"buyer@corp.test", :contact} in emails(archive)
      assert emails(fashion) == []
    end

    test "a stakeholder is a business contact even if they first came in through a sign-up form",
         %{archive: archive, fashion: fashion} do
      %{tenant_id: tenant_id} = paid_tenant()
      Newsletter.subscribe(fashion, "stakeholder@acme.test")

      Subscribers.add_recipient(%{
        tenant_id: tenant_id,
        email: "stakeholder@acme.test",
        authorised_by: "owner@acme.test"
      })

      assert {"stakeholder@acme.test", :contact} in emails(archive)
    end

    test "tenant owners are customers already and are left out of the contact group", %{
      archive: archive
    } do
      paid_tenant(email: "owner@acme.test")

      refute Enum.any?(emails(archive), fn {email, _} -> email == "owner@acme.test" end)
    end

    test "a contact who also subscribed to the archive appears once, as a subscriber", %{
      archive: archive
    } do
      DB.execute("INSERT INTO contacts(email, source) VALUES('both@corp.test', 'import')", [])
      Newsletter.subscribe(archive, "both@corp.test")

      assert Enum.filter(emails(archive), fn {email, _} -> email == "both@corp.test" end) == [
               {"both@corp.test", :subscribed}
             ]
    end
  end

  describe "scheduling" do
    test "sends nothing while EDITION_HOUR is unset", %{fashion: fashion} do
      story(fashion, "a-collection", "A collection arrived")
      Newsletter.subscribe(fashion, "reader@example.test")

      assert Worker.schedule_editions(@after_the_hour) == nil
      assert editions_queued() == []
    end

    test "waits for the hour", %{fashion: fashion} do
      with_edition_hour("15")
      story(fashion, "a-collection", "A collection arrived")
      Newsletter.subscribe(fashion, "reader@example.test")

      assert Worker.schedule_editions(@after_the_hour) == nil
    end

    test "queues each publication's edition once a day, one job per reader", %{
      archive: archive,
      fashion: fashion
    } do
      with_edition_hour("13")
      story(fashion, "a-collection", "A collection arrived")
      story(archive, "a-general-story", "A general story")
      Newsletter.subscribe(fashion, "reader@example.test")
      DB.execute("INSERT INTO contacts(email, source) VALUES('buyer@corp.test', 'import')", [])

      first = Worker.schedule_editions(@after_the_hour)
      second = Worker.schedule_editions(@after_the_hour)
      assert Worker.schedule_editions(@after_the_hour) == nil

      assert Enum.sort([first.publication, second.publication]) == ["archive", "fashion"]

      assert [
               %{
                 to_email: "buyer@corp.test",
                 payload: %{"reason" => "contact", "publication" => "archive"}
               },
               %{
                 to_email: "reader@example.test",
                 payload: %{"reason" => "subscribed", "publication" => "fashion", "date" => @day}
               }
             ] =
               editions_queued()

      assert DB.value("SELECT sum(recipients)::int FROM edition_runs") == 2
    end

    test "skips a publication with nothing published today, and picks it up once something is", %{
      fashion: fashion
    } do
      with_edition_hour("13")
      story(fashion, "yesterdays-collection", "Yesterday's collection", "2026-09-09")
      Newsletter.subscribe(fashion, "reader@example.test")

      assert Worker.schedule_editions(@after_the_hour) == nil

      story(fashion, "todays-collection", "Today's collection")
      assert %{publication: "fashion", recipients: 1} = Worker.schedule_editions(@after_the_hour)
    end
  end

  describe "the email" do
    test "arrives from the publication, headed by the lead, with one-click unsubscribe", %{
      fashion: fashion
    } do
      story(fashion, "a-collection", "A collection arrived")

      message =
        Worker.build_message(%{
          kind: "edition",
          payload: %{
            "publication" => "fashion",
            "date" => @day,
            "reason" => "subscribed",
            "unsubscribeUrl" => "https://rnews1.test/u/t"
          },
          contact_id: nil,
          tenant_id: nil
        })

      assert message.from == ~s("FashionShowOn" <briefings@mg.rnews1.test>)
      assert message.subject == "A collection arrived"
      assert message.html =~ "because you subscribed at"
      assert message.html =~ "https://rnews1.test/u/t"
      assert message.text =~ "https://rnews1.test/u/t"

      assert Enum.any?(message.headers, fn {name, value} ->
               name == "List-Unsubscribe-Post" and value =~ "One-Click"
             end)
    end

    test "tells a business contact the truth about why they have it", %{archive: archive} do
      story(archive, "a-general-story", "A general story")

      message =
        Worker.build_message(%{
          kind: "edition",
          payload: %{
            "publication" => "archive",
            "date" => @day,
            "reason" => "contact",
            "unsubscribeUrl" => "https://rnews1.test/u/t"
          },
          contact_id: nil,
          tenant_id: nil
        })

      assert message.html =~ "as a business contact of RNews1"
      refute message.html =~ "because you subscribed"
    end

    test "a publication name cannot inject a header", %{fashion: fashion} do
      DB.execute("UPDATE publications SET name = $2 WHERE id = $1", [
        fashion.id,
        "Fashion\"\r\nBcc: x@evil.test"
      ])

      story(fashion, "a-collection", "A collection arrived")

      message =
        Worker.build_message(%{
          kind: "edition",
          payload: %{
            "publication" => "fashion",
            "date" => @day,
            "reason" => "subscribed",
            "unsubscribeUrl" => "https://rnews1.test/u/t"
          },
          contact_id: nil,
          tenant_id: nil
        })

      refute message.from =~ "\n"
      refute message.from =~ "\r"
      assert message.from == ~s("FashionBcc: x@evil.test" <briefings@mg.rnews1.test>)
    end

    test "an edition for a publication that no longer exists is not retried" do
      assert_raise Worker.Unbuildable, fn ->
        Worker.build_message(%{
          kind: "edition",
          payload: %{"publication" => "gone", "date" => @day},
          contact_id: nil,
          tenant_id: nil
        })
      end
    end
  end
end
