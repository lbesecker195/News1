defmodule Rnews1.UtilTest do
  use ExUnit.Case, async: true
  alias Rnews1.Util.{HTML, Hosts, Ids, Languages, Markdown, Overlap, Plans, ReadingTime, Slug, Teaser}
  alias Rnews1.Content

  @opts [app_host: "rnews1.test", archive_host: "www.rnews1.test", sites_domain: "rnews1.test"]

  describe "Hosts.classify/2" do
    test "the app host, loopback and IPs are the app" do
      for host <- ["rnews1.test", "localhost", "127.0.0.1", "::1", "RNEWS1.test"] do
        assert Hosts.classify(host, @opts).kind == :app
      end
    end

    test "www is the archive" do
      assert Hosts.classify("www.rnews1.test", @opts) == %{kind: :archive, host: "www.rnews1.test"}
      assert Hosts.classify("WWW.rnews1.test.", @opts).kind == :archive
    end

    test "reserved labels are flagged; tenant labels found; nested labels are nobody's" do
      for host <- ["admin.rnews1.test", "api.rnews1.test", "app.rnews1.test"] do
        assert %{kind: :subdomain, reserved: true} = Hosts.classify(host, @opts)
      end

      assert Hosts.classify("acme.rnews1.test", @opts) == %{kind: :subdomain, label: "acme", host: "acme.rnews1.test", reserved: false}
      assert Hosts.classify("Acme-Robotics.RNEWS1.test", @opts).label == "acme-robotics"
      assert Hosts.classify("a.b.rnews1.test", @opts).kind == :none
      assert Hosts.classify("-x.rnews1.test", @opts).kind == :none
      assert Hosts.classify("news.acme.com", @opts) == %{kind: :custom, host: "news.acme.com"}
    end
  end

  describe "labels" do
    test "accepts ordinary labels and rejects the malformed and reserved" do
      for l <- ["acme", "acme-robotics", "acme-robotics-2", "a1b", String.duplicate("x", 63)] do
        assert Hosts.label_error(l) == nil
      end
      for l <- ["ab", "-acme", "acme-", "Acme", "acme robotics", String.duplicate("x", 64), "", nil] do
        assert Hosts.label_error(l)
      end
      assert Hosts.label_error("www") =~ "reserved"
      assert Hosts.label_error("gmail") =~ "reserved"
      assert Hosts.label_error("xn--acme") =~ "reserved"
    end

    test "suggests from the company name, then the email organisation, else a placeholder" do
      assert Hosts.suggest_label(name: "Acme Robotics, Inc.", email: "j@other.com") == "acme-robotics-inc"
      assert Hosts.suggest_label(name: "Ünïcode Café") == "unicode-cafe"
      assert Hosts.suggest_label(email: "jane@acme.com") == "acme"
      assert Hosts.suggest_label(name: "AB", email: "jane@bigco.io") == "bigco"
      assert Hosts.placeholder_label?(Hosts.suggest_label(email: "jane@gmail.com"))
      assert Hosts.placeholder_label?(Hosts.suggest_label(name: "Admin", email: "x@outlook.com"))
      assert Hosts.placeholder_label?(Hosts.suggest_label())
    end
  end

  describe "site origins and custom hostnames" do
    test "platform address and custom domain" do
      assert Hosts.site_origin(%{subdomain: "acme"}) == "https://acme.rnews1.test"
      assert Hosts.site_origin(%{subdomain: "acme", custom_hostname: "news.acme.com"}) == "https://news.acme.com"
    end

    test "normalises what people paste and refuses what is not a hostname" do
      assert Hosts.normalise_hostname("https://News.Acme.com/path?x=1") == "news.acme.com"
      assert Hosts.normalise_hostname("news.acme.com.") == "news.acme.com"
      assert Hosts.normalise_hostname(" NEWS.ACME.COM:443 ") == "news.acme.com"
      for v <- ["acme", "news_acme.com", "-a.acme.com", "", "a b.com"] do
        assert Hosts.normalise_hostname(v) == nil
      end
    end

    test "keeps the platform's names off the list" do
      assert Hosts.hostname_error("acme.rnews1.test", @opts) =~ "Subdomain field"
      assert Hosts.hostname_error("www.rnews1.test", @opts) =~ "platform"
      assert Hosts.hostname_error("rnews1.test", @opts) =~ "platform"
      assert Hosts.hostname_error("10.0.0.1", @opts) =~ "IP"
      assert Hosts.hostname_error("news.acme.com", @opts) == nil
      production = [app_host: "app.rnews1.test", archive_host: "www.rnews1.test", sites_domain: "rnews1.test"]
      assert Hosts.classify("app.rnews1.test", production).kind == :app
      assert Hosts.classify("www.rnews1.test", production).kind == :archive
      assert Hosts.hostname_error("app.rnews1.test", production) =~ "platform"
    end

    test "company domains" do
      assert Hosts.company_domain("https://www.Example.com/about") == {:ok, "example.com"}
      assert Hosts.company_domain("jane@Acme.io ") == {:ok, "acme.io"}
      assert {:error, _} = Hosts.company_domain("")
      assert {:error, _} = Hosts.company_domain("not a domain")
    end
  end

  describe "Overlap" do
    test "measures shared runs on prose, not figures" do
      source = "The company reported a net loss of $359.5 million for the quarter, citing weaker demand across its consumer division."
      close = "The company reported a net loss of $359.5 million for the quarter, citing weaker demand across the board."
      assert Overlap.longest_shared_run(source, close).prose >= 12
      assert Overlap.too_close?(source, close)
      refute Overlap.too_close?(source, "Demand fell in consumer products, and a quarterly loss of $359.5 million followed.")
      assert Overlap.longest_shared_run("", "x") == %{length: 0, prose: 0, phrase: ""}
    end
  end

  describe "Teaser" do
    test "first sentence, trailing off" do
      assert Teaser.first_sentence("Rates rose again. Analysts expect more.") == "Rates rose again…"
      assert Teaser.first_sentence("U.S. regulators moved first. Europe followed.") == "U.S. regulators moved first…"
      assert Teaser.first_sentence("A headline with no ending") == "A headline with no ending…"
      assert Teaser.first_sentence("Really?! Yes.") == "Really…"
      assert Teaser.first_sentence("  spaced   out.  ") == "spaced out…"
      assert Teaser.first_sentence("") == ""
      long = String.duplicate("word ", 60) |> String.trim()
      t = Teaser.first_sentence(long <> ".", 50)
      assert String.length(t) <= 51 and String.ends_with?(t, "…")
    end
  end

  describe "Slug, Markdown, ReadingTime, Ids, HTML, Plans, Languages, Content" do
    test "slugify" do
      assert Slug.slugify("Café au lait: it's back!") == "cafe-au-lait-its-back"
      assert Slug.label("Acme Robotics, Inc.") == "acme-robotics-inc"
    end

    test "markdown escapes before it adds tags" do
      html = Markdown.render("## Heading\n\nA **bold** <script>x</script> [link](https://e.com/x)\n\n- one\n- two")
      assert html =~ "<h3>Heading</h3>"
      assert html =~ "<strong>bold</strong>"
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
      assert html =~ ~s(<a href="https://e.com/x" rel="noopener noreferrer">link</a>)
      assert html =~ "<ul><li>one</li><li>two</li></ul>"
    end

    test "reading time counts words or CJK characters" do
      assert ReadingTime.minutes(String.duplicate("word ", 440)) == 2
      assert ReadingTime.minutes(String.duplicate("字", 1000)) == 2
      assert ReadingTime.minutes("") == 0
      assert ReadingTime.from_length(0) == 1
    end

    test "ids" do
      assert Ids.uuid?("550e8400-e29b-41d4-a716-446655440000")
      refute Ids.uuid?("nope")
      assert Ids.login_token?(Ids.token())
      assert String.length(Ids.token()) == 43
      assert Ids.hash("a") == "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"
    end

    test "safe urls and escaping" do
      assert HTML.safe_url("javascript:alert(1)") == "#"
      assert HTML.safe_url("https://example.com/a?b=c") == "https://example.com/a?b=c"
      assert HTML.escape(~s(<a href="x">'&')) == "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;"
    end

    test "plans and comps" do
      assert Plans.entitlements(%{plan: "enterprise"}) |> Map.take([:customDomain, :branding]) == %{customDomain: true, branding: false}
      assert Plans.entitlements(%{plan: "standard"}).branding
      assert Plans.entitlements(nil).plan == "standard"
      assert Plans.comped?(%{comped_reason: "demo"})
      refute Plans.comped?(%{comped_reason: nil})
    end

    test "languages" do
      assert length(Languages.codes()) == 12
      assert Languages.name("es") == "Español"
      assert Languages.direction("ar") == "rtl"
      assert Languages.direction("en") == "ltr"
      refute Languages.language?("privacy")
    end

    test "content fill and defaults" do
      assert Content.fill("{{company}} · {{count}} · {{nope}}", %{company: "Acme", count: 3}) == "Acme · 3 · {{nope}}"
      assert Content.report().labels.readStory == "Read the full story"
      assert Content.brand().tagline == "Real News, made for One."
    end
  end
end
