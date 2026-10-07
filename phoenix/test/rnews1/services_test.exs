defmodule Rnews1.ServicesTest do
  use ExUnit.Case, async: true
  alias Rnews1.{Domains, Extract, IssueMail, MailgunWebhook}
  alias Rnews1Web.ArchiveController

  describe "Extract" do
    test "robots: our group wins, then the wildcard; longest match decides" do
      rules =
        Extract.parse_robots(
          "User-agent: *\nDisallow: /news/\nAllow: /news/public/\n\nUser-agent: rnews1\nDisallow: /private/"
        )

      assert rules == [%{path: "/private/", allow: false}]
      wildcard = Extract.parse_robots("User-agent: *\nDisallow: /news/\nAllow: /news/public/")
      assert length(wildcard) == 2
      assert Extract.parse_robots("# nothing") == nil
    end

    test "extracts JSON-LD articleBody first, then <article>, then paragraphs" do
      body = String.duplicate("A sentence of real reporting that goes on for a while. ", 12)

      jsonld =
        ~s(<html><script type="application/ld+json">{"@type":"NewsArticle","articleBody":"#{body}"}</script><p>#{body}</p></html>)

      assert %{method: "jsonld"} = Extract.extract_article_text(jsonld)

      article =
        "<html><nav><p>#{body}</p></nav><article><p>#{body}</p><p>#{body}</p></article></html>"

      assert %{method: "articletag", text: text} = Extract.extract_article_text(article)
      refute text =~ "nav"
      paragraphs = "<html><p>#{body}</p><p>#{body}</p></html>"
      assert %{method: "paragraphs"} = Extract.extract_article_text(paragraphs)
      assert Extract.extract_article_text("<p>short</p>") == nil
    end

    test "cleans entities and tags" do
      assert Extract.clean("<b>Tom &amp; Jerry&rsquo;s &#8212; &#x27;x&#x27;</b>") ==
               "Tom & Jerry’s — 'x'"
    end

    test "decodes the old Google News link format" do
      encoded = Base.url_encode64("\x08\x13\"https://example.com/story/1\xd2\x01", padding: false)

      assert Extract.decode_google_news_url(
               "https://news.google.com/rss/articles/#{encoded}?oc=5"
             ) == "https://example.com/story/1"

      assert Extract.decode_google_news_url("https://example.com") == nil
    end
  end

  describe "Domains.check_domain/3" do
    @tenant %{subdomain: "acme"}
    @domain %{hostname: "news.acme.com", verification_token: "tok123"}

    test "a CNAME to the tenant's own subdomain verifies; another tenant's does not" do
      ok = %{cname: fn _ -> {:ok, ["ACME.rnews1.test."]} end, txt: fn _ -> {:error, :nodata} end}
      assert Domains.check_domain(@domain, @tenant, ok) == %{ok: true, method: "cname"}

      rival = %{
        cname: fn _ -> {:ok, ["rival.rnews1.test"]} end,
        txt: fn _ -> {:error, :nodata} end
      }

      result = Domains.check_domain(@domain, @tenant, rival)
      refute result.ok
      assert result.reason =~ "rival.rnews1.test, not to acme.rnews1.test"
    end

    test "falls back to the TXT record and explains absence vs failure" do
      txt = %{
        cname: fn _ -> {:error, :nodata} end,
        txt: fn name ->
          assert name == "_rnews1.news.acme.com"
          {:ok, ["rnews1-verify=tok123", "other"]}
        end
      }

      assert Domains.check_domain(@domain, @tenant, txt) == %{ok: true, method: "txt"}
      absent = %{cname: fn _ -> {:error, :nxdomain} end, txt: fn _ -> {:error, :nxdomain} end}

      assert Domains.check_domain(@domain, @tenant, absent).reason =~
               "No CNAME to acme.rnews1.test"

      broken = %{cname: fn _ -> {:error, :timeout} end, txt: fn _ -> {:error, :timeout} end}

      assert Domains.check_domain(@domain, @tenant, broken).reason =~
               "DNS lookup failed (TIMEOUT)"

      [cname, txtrec] = Domains.dns_records(@domain, @tenant)

      assert {cname.type, cname.name, cname.value} ==
               {"CNAME", "news.acme.com", "acme.rnews1.test"}

      assert {txtrec.type, txtrec.name, txtrec.value} ==
               {"TXT", "_rnews1.news.acme.com", "rnews1-verify=tok123"}
    end
  end

  describe "MailgunWebhook" do
    defp signed(token \\ "t", ts \\ to_string(System.os_time(:second))) do
      sig = :crypto.mac(:hmac, :sha256, "signing-key", ts <> token) |> Base.encode16(case: :lower)
      %{"signature" => %{"timestamp" => ts, "token" => token, "signature" => sig}}
    end

    test "a good signature applies the event; a bad one is refused before any work" do
      applied = self()

      body =
        Map.put(signed(), "event-data", %{
          "id" => "ev1",
          "event" => "failed",
          "severity" => "permanent",
          "recipient" => "A@B.com",
          "user-variables" => %{"job_id" => "550e8400-e29b-41d4-a716-446655440000"}
        })

      MailgunWebhook.process(body, fn event ->
        send(applied, {:applied, event})
        true
      end)

      assert_received {:applied,
                       %{
                         kind: "hard_bounce",
                         email: "a@b.com",
                         job_id: "550e8400-e29b-41d4-a716-446655440000"
                       }}

      bad = put_in(signed(), ["signature", "signature"], String.duplicate("0", 64))

      assert_raise Rnews1.HttpError, ~r/Invalid Mailgun signature/, fn ->
        MailgunWebhook.process(
          Map.put(bad, "event-data", %{"id" => "x", "event" => "accepted"}),
          fn _ -> flunk("must not apply") end
        )
      end

      stale = signed("t", "1000")

      assert_raise Rnews1.HttpError, fn ->
        MailgunWebhook.process(stale, fn _ -> flunk("must not apply") end)
      end
    end

    test "accepts a callback signed with any of the domain's webhook keys" do
      previous = Application.get_env(:rnews1, :env)

      Application.put_env(
        :rnews1,
        :env,
        Keyword.put(previous, :mailgun_signing_key, " first-key , signing-key,third-key ")
      )

      on_exit(fn -> Application.put_env(:rnews1, :env, previous) end)

      assert Rnews1.Env.mailgun_signing_keys() == ["first-key", "signing-key", "third-key"]

      applied = self()

      for key <- ["first-key", "signing-key", "third-key"] do
        ts = to_string(System.os_time(:second))
        sig = :crypto.mac(:hmac, :sha256, key, ts <> "t") |> Base.encode16(case: :lower)

        body = %{
          "signature" => %{"timestamp" => ts, "token" => "t", "signature" => sig},
          "event-data" => %{"id" => "ev-#{key}", "event" => "complained", "recipient" => "a@b.com"}
        }

        MailgunWebhook.process(body, fn event -> send(applied, {:applied, event.id}) end)
        assert_received {:applied, _}
      end

      ts = to_string(System.os_time(:second))
      forged = :crypto.mac(:hmac, :sha256, "not-a-key", ts <> "t") |> Base.encode16(case: :lower)

      assert_raise Rnews1.HttpError, ~r/Invalid Mailgun signature/, fn ->
        MailgunWebhook.process(
          %{
            "signature" => %{"timestamp" => ts, "token" => "t", "signature" => forged},
            "event-data" => %{"id" => "x", "event" => "accepted"}
          },
          fn _ -> flunk("must not apply") end
        )
      end
    end

    test "refuses every callback when no signing key is configured" do
      previous = Application.get_env(:rnews1, :env)
      Application.put_env(:rnews1, :env, Keyword.put(previous, :mailgun_signing_key, ""))
      on_exit(fn -> Application.put_env(:rnews1, :env, previous) end)

      assert Rnews1.Env.mailgun_signing_keys() == []

      assert_raise Rnews1.HttpError, ~r/Invalid Mailgun signature/, fn ->
        MailgunWebhook.process(
          Map.put(signed(), "event-data", %{"id" => "x", "event" => "accepted"}),
          fn _ -> flunk("must not apply") end
        )
      end
    end
  end

  describe "IssueMail" do
    test "carries the address, the unsubscribe link and labelled sponsorship" do
      story = %{
        headline: "H",
        standfirst: "S",
        body: "P1\n\nP2",
        source_name: "Times",
        source_url: "https://t.com/a"
      }

      ad = %{
        headline: "Buy",
        body: "Now",
        cta: "Go",
        click_url: "https://rnews1.test/a/c/1",
        pixel_url: "https://rnews1.test/a/p/1.gif"
      }

      html =
        IssueMail.render_html(%{
          company: "Acme & Co",
          date: "2026-09-10",
          stories: [story, story],
          ads: %{sponsored: ad, banners: [ad]},
          unsubscribe_url: "https://rnews1.test/u/tok",
          reader: %{reason: "your role"}
        })

      assert html =~ "Acme &amp; Co"
      assert html =~ "Sponsored"
      assert html =~ "Picked for you · your role"
      assert html =~ "1 Test St, Springfield, CA 90000"
      assert html =~ "/u/tok"
      assert html =~ "/a/p/1.gif"

      text =
        IssueMail.render_text(%{
          company: "Acme",
          date: "d",
          stories: [story],
          ads: %{sponsored: ad},
          unsubscribe_url: "u"
        })

      assert text =~ "— SPONSORED —"
      assert text =~ "Unsubscribe: u"
    end
  end

  describe "ArchiveController.preferred_language/2" do
    test "picks the best-ranked language we publish in, else English" do
      assert ArchiveController.preferred_language("es-MX,es;q=0.9,en;q=0.5") == "es"
      assert ArchiveController.preferred_language("de-DE,de;q=0.9,fr;q=0.8") == "fr"
      assert ArchiveController.preferred_language("zh-Hant-TW") == "zh"
      assert ArchiveController.preferred_language("pt-BR;q=0.3, ar;q=0.8") == "ar"
      assert ArchiveController.preferred_language("") == "en"
      assert ArchiveController.preferred_language(nil) == "en"
      assert ArchiveController.preferred_language("sw,xx;q=0.5") == "en"
    end
  end

  describe "EventController.redact/1" do
    test "takes the credentials out of a path" do
      assert Rnews1Web.EventController.redact("/brief/37dd4a93-a6b7-426d-b2b1-a72fc09102ae") ==
               "/brief/:id"

      assert Rnews1Web.EventController.redact("/login/" <> String.duplicate("a", 43)) ==
               "/login/:token"

      assert Rnews1Web.EventController.redact("/en/usa/a-story/2026-09-10") ==
               "/en/usa/a-story/2026-09-10"
    end
  end

  describe "PDF" do
    test "reads the page count out of Chrome's output" do
      assert Rnews1.PDF.page_count("%PDF-1.4\n<</Type /Pages /Kids [1 0 R] /Count 2>>") == 2
      assert Rnews1.PDF.page_count("nothing") == 1
    end
  end
end

defmodule Rnews1.PDFStarterTest do
  use ExUnit.Case, async: false

  test "CHROME_EXECUTABLE=none switches PDFs off" do
    previous = Application.get_env(:rnews1, :env, [])
    Application.put_env(:rnews1, :env, Keyword.put(previous, :chrome_executable, "none"))
    on_exit(fn -> Application.put_env(:rnews1, :env, previous) end)
    assert Rnews1.PDF.chrome_path() == nil
    assert Rnews1.PDF.child_spec_if_available() == nil
  end

  @tag timeout: 30_000
  test "a browser that cannot run costs the PDFs, not the node" do
    test = self()

    # First start: a browser that dies at once. Every later start: refused.
    start = fn _opts ->
      send(test, :started)

      case Process.get(:starts, 0) do
        0 ->
          Process.put(:starts, 1)

          {:ok,
           spawn_link(fn ->
             Process.sleep(20)
             exit(:crashed)
           end)}

        _ ->
          {:error, :no_browser}
      end
    end

    {:ok, pid} =
      Rnews1.PDF.Starter.start_link(
        name: :pdf_starter_test,
        start: start,
        chrome_executable: "/bin/false"
      )

    ref = Process.monitor(pid)

    # It tried, retried, and then gave up without taking the test process with it.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 25_000
    assert_received :started
    assert_received :started
    assert_received :started
    refute_received :started
  end
end

defmodule Rnews1.PDFShimTest do
  use ExUnit.Case, async: false

  test "a script that runs the chromium snap is not a browser" do
    dir = Path.join(System.tmp_dir!(), "rnews1-shim-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    shim = Path.join(dir, "chromium-browser")

    File.write!(
      shim,
      "#!/bin/sh\nif ! [ -x /snap/bin/chromium ]; then exit 1; fi\nexec /snap/bin/chromium \"$@\"\n"
    )

    File.chmod!(shim, 0o755)

    previous = Application.get_env(:rnews1, :env, [])
    Application.put_env(:rnews1, :env, Keyword.put(previous, :chrome_executable, shim))

    on_exit(fn ->
      Application.put_env(:rnews1, :env, previous)
      File.rm_rf!(dir)
    end)

    refute Rnews1.PDF.chrome_path() == shim
  end
end
