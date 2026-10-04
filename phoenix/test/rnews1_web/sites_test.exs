defmodule Rnews1Web.SitesTest do
  use Rnews1Web.ConnCase, async: false
  alias Rnews1.{Domains, House, Sites, Subscribers}
  alias Rnews1.Util.Hosts

  @published Subscribers.required_stakeholders()

  describe "subdomains" do
    test "a new tenant gets a label from their email domain; collisions are numbered" do
      first = tenant_row(new_tenant("jane@acme.test"))
      second = tenant_row(new_tenant("bob@acme.test"))
      assert first.subdomain == "acme"
      assert second.subdomain == "acme-2"
      assert new_tenant("jane@acme.test") == first.id
    end

    test "a freemail sign-up gets a placeholder, then the company name" do
      id = new_tenant("jane@gmail.com")
      assert Hosts.placeholder_label?(tenant_row(id).subdomain)
      Sites.adopt_name_label(id, "Bright Widgets Ltd")
      assert tenant_row(id).subdomain == "bright-widgets-ltd"
      assert {:ok, "brightwidgets"} = Sites.rename(id, "brightwidgets")
    end
  end

  describe "routing by host" do
    test "serves a published tenant's site at their subdomain, with canonical links", %{conn: conn} do
      %{story: story} = paid_tenant(stakeholders: @published)
      home = conn |> on_host("acme.rnews1.test") |> get("/")
      assert home.status == 200
      assert body_of(home) =~ "Acme Robotics"
      assert body_of(home) =~ "https://acme.rnews1.test/news/#{story.id}"
      refute body_of(home) =~ ">Sign in<"
      assert body_of(home) =~ ~s(<link rel="canonical" href="https://acme.rnews1.test/">)

      assert (conn |> on_host("acme.rnews1.test") |> get("/news/#{story.id}")).status == 200
      feed = conn |> on_host("acme.rnews1.test") |> get("/feed.xml")
      assert feed.status == 200
      assert body_of(feed) =~ "<link>https://acme.rnews1.test/</link>"
      assert (conn |> on_host("acme.rnews1.test") |> get("/embed")).status == 200
      assert body_of(conn |> on_host("acme.rnews1.test") |> get("/robots.txt")) =~ "Sitemap: https://acme.rnews1.test/sitemap.xml"
      assert body_of(conn |> on_host("acme.rnews1.test") |> get("/sitemap.xml")) =~ "<loc>https://acme.rnews1.test/news/#{story.id}</loc>"
    end

    test "keeps the app off customer hosts; 404s unknown labels; coming soon before the roster", %{conn: conn} do
      paid_tenant(stakeholders: @published)
      for path <- ["/app", "/api/me", "/admin", "/login", "/privacy"] do
        assert (conn |> on_host("acme.rnews1.test") |> get(path)).status == 404
      end
      # A subdomain nobody has claimed goes to the app, where the visitor can
      # start one. Temporary and uncached: the label is free to claim tomorrow,
      # and a cached permanent redirect would hide the site that claims it.
      nobody = conn |> on_host("nobody.rnews1.test") |> get("/en/anything")
      assert nobody.status == 302
      assert location(nobody) == "https://rnews1.test/"
      assert get_resp_header(nobody, "cache-control") == ["no-store"]

      # A reserved label has no site either, and goes to the same place.
      assert location(conn |> on_host("mail.rnews1.test") |> get("/")) == "https://rnews1.test/"
    end

    test "a claimed label stops redirecting the moment it has a site", %{conn: conn} do
      before = conn |> on_host("claimed-later.rnews1.test") |> get("/")
      assert before.status == 302

      %{tenant_id: id} = paid_tenant(email: "later@acme.test", stakeholders: @published)
      DB.execute("UPDATE tenants SET subdomain = 'claimed-later' WHERE id = $1", [id])

      refute (conn |> on_host("claimed-later.rnews1.test") |> get("/")).status == 302
    end

    test "a custom domain with no site is left alone rather than sent to the app", %{conn: conn} do
      # Usually a customer partway through setting it up: telling them nothing is
      # there yet is more useful than bouncing them to a sign-up page.
      r = conn |> on_host("news.unclaimed.test") |> get("/")
      assert r.status == 404
      assert body_of(r) =~ "No site is set up at news.unclaimed.test"
    end

    test "shows coming soon while unpublished, and the app host still works", %{conn: conn} do
      %{story: story, tenant: tenant} = paid_tenant(stakeholders: @published - 2)
      for path <- ["/", "/news/#{story.id}", "/feed.xml", "/embed"] do
        r = conn |> on_host("acme.rnews1.test") |> get(path)
        assert r.status == 409, path
        assert body_of(r) =~ "coming soon"
      end
      assert body_of(conn |> on_host("acme.rnews1.test") |> get("/robots.txt")) =~ "Disallow: /"
      assert (conn |> get("/")).status == 200
      assert (conn |> get("/news/#{tenant.public_token}/#{story.id}")).status == 409
    end

    test "the coming-soon page can still be framed when it is the embed that is refused", %{conn: conn} do
      paid_tenant(stakeholders: @published - 2)

      # A customer who pastes the snippet before the gate opens, and the
      # dashboard's own preview, have to see this page rather than the blank
      # box a browser leaves when it refuses the frame outright.
      refused = conn |> on_host("acme.rnews1.test") |> get("/embed")
      assert refused.status == 409
      assert body_of(refused) =~ "coming soon"
      assert hd(get_resp_header(refused, "content-security-policy")) =~ "frame-ancestors *"
      assert get_resp_header(refused, "x-frame-options") == []

      # The site's other pages are not framable; only the embed route is.
      root = conn |> on_host("acme.rnews1.test") |> get("/")
      assert hd(get_resp_header(root, "content-security-policy")) =~ "frame-ancestors 'self'"
    end

    test "legacy token URLs on the tenant host redirect; the app host declares the site canonical", %{conn: conn} do
      %{story: story, tenant: tenant} = paid_tenant(stakeholders: @published)
      r = conn |> on_host("acme.rnews1.test") |> get("/news/#{tenant.public_token}/#{story.id}")
      assert r.status == 302 and location(r) == "/news/#{story.id}"
      assert (conn |> on_host("acme.rnews1.test") |> get("/feed/00000000-0000-4000-8000-000000000000.xml")).status == 404
      legacy = conn |> get("/news/#{tenant.public_token}/#{story.id}")
      assert legacy.status == 200
      assert body_of(legacy) =~ ~s(<link rel="canonical" href="https://acme.rnews1.test/news/#{story.id}">)
      assert (conn |> get("/feed/#{tenant.public_token}.xml")).status == 200
    end
  end

  describe "renaming" do
    test "renames once, redirects the old address, then waits a day", %{conn: conn} do
      %{tenant_id: id, story: story} = paid_tenant(stakeholders: @published)
      s = session_for(id)
      me = conn |> as_tenant(s) |> get("/api/me") |> json_of()
      assert me["site"]["origin"] == "https://acme.rnews1.test"
      assert me["rss"] == "https://acme.rnews1.test/feed.xml"
      assert me["site"]["rename"]["allowed"]

      renamed = conn |> as_tenant(s) |> post("/api/site/subdomain", %{subdomain: "Acme-News"})
      assert renamed.status == 200
      assert json_of(renamed)["site"]["subdomain"] == "acme-news"

      moved = conn |> on_host("acme.rnews1.test") |> get("/news/#{story.id}")
      assert moved.status == 301 and location(moved) == "https://acme-news.rnews1.test/news/#{story.id}"
      assert (conn |> on_host("acme-news.rnews1.test") |> get("/")).status == 200

      again = conn |> as_tenant(s) |> post("/api/site/subdomain", %{subdomain: "acme-daily"})
      assert again.status == 429
      assert header(again, "retry-after")
      assert json_of(again)["error"] =~ "once every 24 hours"

      DB.execute("UPDATE tenants SET subdomain_changed_at = now() - interval '25 hours' WHERE id = $1", [id])
      assert (conn |> as_tenant(s) |> post("/api/site/subdomain", %{subdomain: "acme-daily"})).status == 200
    end

    test "refuses reserved, malformed, taken and recently released labels", %{conn: conn} do
      %{tenant_id: id} = paid_tenant()
      s = session_for(id)
      rival = paid_tenant(email: "owner@rival.test", name: "Rival")
      assert {:ok, _} = Sites.rename(rival.tenant_id, "rival-news")
      for {label, status} <- [{"admin", 400}, {"ab", 400}, {"Has Spaces", 400}, {"rival-news", 409}, {"rival", 409}, {"acme", 400}, {"www", 400}] do
        assert (conn |> as_tenant(s) |> post("/api/site/subdomain", %{subdomain: label})).status == status, label
      end
      DB.execute("UPDATE tenants SET subdomain_changed_at = NULL WHERE id = $1", [rival.tenant_id])
      assert {:ok, "rival"} = Sites.rename(rival.tenant_id, "rival")
    end
  end

  describe "custom domains" do
    defp pointed, do: %{cname: fn _ -> {:ok, ["acme.rnews1.test."]} end, txt: fn _ -> {:error, :nodata} end}
    defp gone, do: %{cname: fn _ -> {:error, :nxdomain} end, txt: fn _ -> {:error, :nxdomain} end}

    test "served only once DNS proves it, then canonical; sitemap and tls-ask follow", %{conn: conn} do
      %{tenant_id: id, story: story} = paid_tenant(stakeholders: @published)
      s = session_for(id)
      claimed = conn |> as_tenant(s) |> post("/api/site/domain", %{hostname: "https://News.Acme.test/"})
      assert claimed.status == 200
      site = json_of(claimed)["site"]
      assert site["domain"]["hostname"] == "news.acme.test"
      refute site["domain"]["verified"]
      assert Enum.map(site["domain"]["records"], &{&1["type"], &1["name"], &1["value"]}) |> hd() == {"CNAME", "news.acme.test", "acme.rnews1.test"}

      assert (conn |> on_host("news.acme.test") |> get("/")).status == 404
      assert (conn |> get("/.well-known/tls-ask?domain=news.acme.test")).status == 404

      assert Domains.verify_now(id, pointed()).check.ok
      live = conn |> on_host("news.acme.test") |> get("/news/#{story.id}")
      assert live.status == 200
      assert body_of(live) =~ ~s(<link rel="canonical" href="https://news.acme.test/news/#{story.id}">)
      platform = conn |> on_host("acme.rnews1.test") |> get("/news/#{story.id}")
      assert platform.status == 301 and location(platform) == "https://news.acme.test/news/#{story.id}"

      me = conn |> as_tenant(s) |> get("/api/me") |> json_of()
      assert me["site"]["origin"] == "https://news.acme.test"
      assert me["embed"] == "https://news.acme.test/embed"

      sitemap = conn |> on_host("news.acme.test") |> get("/sitemap.xml")
      assert body_of(sitemap) =~ "<loc>https://news.acme.test/</loc>"
      refute body_of(sitemap) =~ "acme.rnews1.test"
      assert body_of(sitemap) =~ ~r/<lastmod>\d{4}-\d{2}-\d{2}<\/lastmod>/

      for {host, status} <- [{"news.acme.test", 200}, {"acme.rnews1.test", 200}, {"rnews1.test", 200}, {"www.rnews1.test", 200}, {"nobody.rnews1.test", 404}, {"evil.example", 404}, {"", 404}, {"10.0.0.1", 404}] do
        assert (conn |> get("/.well-known/tls-ask?domain=#{host}")).status == status, host
      end

      removed = conn |> as_tenant(s) |> delete("/api/site/domain")
      assert json_of(removed)["site"]["origin"] == "https://acme.rnews1.test"
      assert (conn |> on_host("news.acme.test") |> get("/")).status == 404
    end

    test "rejects platform hostnames and a CNAME at somebody else's site", %{conn: conn} do
      %{tenant_id: id} = paid_tenant(stakeholders: @published)
      s = session_for(id)
      for h <- ["acme.rnews1.test", "rnews1.test", "www.rnews1.test", "10.0.0.1", "not a host"] do
        assert (conn |> as_tenant(s) |> post("/api/site/domain", %{hostname: h})).status == 400, h
      end
      conn |> as_tenant(s) |> post("/api/site/domain", %{hostname: "news.acme.test"})
      elsewhere = Domains.verify_now(id, %{pointed() | cname: fn _ -> {:ok, ["rival.rnews1.test"]} end})
      refute elsewhere.check.ok
      assert (conn |> on_host("news.acme.test") |> get("/")).status == 404
    end

    test "a verified claim stands; an unverified one gives way; DNS wobbles are tolerated" do
      acme = paid_tenant()
      rival = paid_tenant(email: "owner@rival.test", name: "Rival")
      assert {:ok, _} = Sites.claim_custom_domain(acme.tenant_id, "news.shared.test")
      assert {:ok, second} = Sites.claim_custom_domain(rival.tenant_id, "news.shared.test")
      assert Sites.custom_domain_for(acme.tenant_id) == nil
      Sites.record_check(second.id, %{ok: true})
      assert {:error, :taken} = Sites.claim_custom_domain(acme.tenant_id, "news.shared.test")

      %{tenant_id: id} = paid_tenant(email: "owner@wobble.test", name: "Wobble", stakeholders: @published)
      Sites.claim_custom_domain(id, "news.wobble.test")
      Domains.verify_now(id, %{cname: fn _ -> {:ok, ["wobble.rnews1.test"]} end, txt: fn _ -> {:error, :nodata} end})
      DB.execute("UPDATE tenant_domains SET last_checked_at = now() - interval '2 days' WHERE hostname = 'news.wobble.test'")
      assert Domains.recheck_domains(resolver: gone()).failing == 1
      assert Sites.find_by_custom_hostname("news.wobble.test"), "still served after one blip"
      DB.execute("UPDATE tenant_domains SET failing_since = now() - interval '4 days', last_checked_at = now() - interval '2 days' WHERE hostname = 'news.wobble.test'")
      Domains.recheck_domains(resolver: gone())
      refute Sites.find_by_custom_hostname("news.wobble.test")
    end
  end

  describe "plans and the house account" do
    test "custom domains and unbranded embeds are enterprise; comped accounts never reach PayPal", %{conn: conn} do
      standard = paid_tenant(plan: "standard", stakeholders: @published)
      s = session_for(standard.tenant_id)
      me = conn |> as_tenant(s) |> get("/api/me") |> json_of()
      assert me["tenant"]["plan"] == "standard"
      refute me["site"]["entitlements"]["customDomain"]
      refused = conn |> as_tenant(s) |> post("/api/site/domain", %{hostname: "news.acme.test"})
      assert refused.status == 403 and json_of(refused)["error"] =~ "enterprise plan"
      assert (conn |> as_tenant(s) |> post("/api/site/subdomain", %{subdomain: "acme-news"})).status == 200

      big = paid_tenant(email: "owner@big.test", name: "Big Corp", plan: "enterprise", stakeholders: @published)
      assert body_of(conn |> on_host("acme-news.rnews1.test") |> get("/embed")) =~ "Powered by Rnews1"
      refute body_of(conn |> on_host("big.rnews1.test") |> get("/embed")) =~ "Powered by Rnews1"

      DB.execute("UPDATE tenants SET comped_reason = 'demo' WHERE id = $1", [big.tenant_id])
      bs = session_for(big.tenant_id)
      for path <- ["/api/checkout", "/api/cancel"] do
        r = conn |> as_tenant(bs) |> post(path, %{})
        assert r.status == 409 and json_of(r)["error"] =~ "not billed"
      end
    end

    test "www is the archive: unclaimable, and the house account owns it as a publication", %{conn: conn} do
      # The archive is a publication now, not this tenant's site. The house
      # account owns it, but its own briefing must not sit on the archive's
      # host: the archive router serves no feed, no embed and no hosted
      # article, so a tenant parked there advertises three URLs that 404.
      house = House.ensure_house_account("me@rnews1.test")
      assert house.plan == "enterprise" and house.comped_reason
      refute house.subdomain == "www"

      id = DB.value("SELECT id FROM tenants WHERE owner_email = 'me@rnews1.test'")
      assert Enum.map(Rnews1.Publications.list_for_tenant(id), & &1.slug) == ["archive"]

      s = session_for(id)
      me = conn |> as_tenant(s) |> get("/api/me") |> json_of()
      refute me["site"]["origin"] == "https://www.rnews1.test"
      assert me["site"]["entitlements"]["comped"]

      # The archive still serves at www, from the archive router.
      root = conn |> on_host("www.rnews1.test") |> get("/")
      assert root.status == 302 and location(root) == "/en"

      # Idempotent: a second boot neither moves it again nor puts it back.
      assert House.ensure_house_account("me@rnews1.test").subdomain == house.subdomain

      squatter = paid_tenant(email: "squatter@acme.test")
      DB.execute("UPDATE tenants SET subdomain = 'www2' WHERE id = $1", [squatter.tenant_id])
      assert (conn |> as_tenant(session_for(squatter.tenant_id)) |> post("/api/site/domain", %{hostname: "www.rnews1.test"})).status == 400
    end
  end
end
