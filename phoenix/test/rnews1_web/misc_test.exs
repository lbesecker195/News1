defmodule Rnews1Web.MiscTest do
  use Rnews1Web.ConnCase, async: false
  alias Rnews1.{Admins, Clicks, DB, Outbox, Worker}

  describe "click tracking" do
    test "records, attributes, redacts, ignores junk, works on every host", %{conn: conn} do
      r = conn |> post("/e", %{events: [%{kind: "link", path: "/en/technology", target: "/en/technology/a-story/2026-09-10", label: "A story headline", external: false}]})
      assert r.status == 204 and header(r, "cache-control") == "no-store"
      [row] = DB.all("SELECT * FROM click_events")
      assert {row.kind, row.path, row.target, row.label, row.external, row.tenant_id} == {"link", "/en/technology", "/en/technology/a-story/2026-09-10", "A story headline", false, nil}

      %{tenant_id: id} = paid_tenant()
      conn |> on_host("acme.rnews1.test") |> post("/e", %{events: [%{kind: "button", target: "subscribe", label: "Subscribe"}]})
      assert DB.one("SELECT * FROM click_events WHERE kind = 'button'").tenant_id == id

      conn |> post("/e", %{events: [%{kind: "link", path: "/brief/37dd4a93-a6b7-426d-b2b1-a72fc09102ae", target: "/u/" <> String.duplicate("a", 43), label: "Unsubscribe"}]})
      redacted = DB.one("SELECT * FROM click_events WHERE label = 'Unsubscribe'")
      assert {redacted.path, redacted.target} == {"/brief/:id", "/u/:token"}

      before = DB.value("SELECT count(*) FROM click_events")
      for body <- [%{events: []}, %{events: [%{kind: "nonsense"}]}, %{nothing: true}, %{}] do
        assert (conn |> post("/e", body)).status == 204
      end
      assert DB.value("SELECT count(*) FROM click_events") == before
      assert (conn |> on_host("www.rnews1.test") |> post("/e", %{events: [%{kind: "link", path: "/", target: "/x"}]})).status == 204

      top = Clicks.top_targets(host: "rnews1.test")
      assert Enum.any?(top, &(&1.target == "/en/technology/a-story/2026-09-10"))
      DB.execute("UPDATE click_events SET occurred_at = now() - interval '200 days' WHERE kind = 'button'")
      assert Clicks.prune() == 1
    end
  end

  describe "ads" do
    test "pixel always returns a gif; click counts and redirects; unknown 404s", %{conn: conn} do
      DB.execute("INSERT INTO advertisers(id, name) VALUES('11111111-1111-4111-8111-111111111111','Ad Co')")
      DB.execute("INSERT INTO campaigns(id, advertiser_id, name, status, starts_on, ends_on, cpm_cents) VALUES('22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111','C','active',current_date, current_date + 1, 500)")
      DB.execute("INSERT INTO creatives(id, campaign_id, slot, headline, body, click_url) VALUES('33333333-3333-4333-8333-333333333333','22222222-2222-4222-8222-222222222222','banner','H','B','https://advertiser.example/offer')")
      placement = Rnews1.Ads.record_placement(%{campaign_id: "22222222-2222-4222-8222-222222222222", creative_id: "33333333-3333-4333-8333-333333333333", issue_date: Date.utc_today(), slot: "banner"})

      px = conn |> get("/a/p/#{placement}.gif")
      assert px.status == 200 and header(px, "content-type") =~ "image/gif"
      assert (conn |> get("/a/p/not-a-uuid.gif")).status == 200
      assert DB.value("SELECT count(*) FROM ad_events WHERE kind = 'impression'") == 1

      click = conn |> get("/a/c/#{placement}")
      assert click.status == 302 and location(click) == "https://advertiser.example/offer"
      assert DB.value("SELECT clicks FROM campaigns WHERE id = '22222222-2222-4222-8222-222222222222'") == 1
      assert (conn |> get("/a/c/00000000-0000-4000-8000-000000000000")).status == 404
      assert (conn |> get("/a/c/nope")).status == 404
    end
  end

  describe "admin" do
    test "password sign-in, dashboard, and the ad-server forms", %{conn: conn} do
      Admins.upsert(%{email: "staff@rnews1.test", password: "staff-password"})
      assert (conn |> get("/admin")).status == 302
      bad = conn |> with_origin() |> post("/admin/login", %{email: "staff@rnews1.test", password: "wrong"})
      assert bad.status == 401 and body_of(bad) =~ "not recognised"
      ok = conn |> with_origin() |> post("/admin/login", %{email: "staff@rnews1.test", password: "staff-password"})
      assert ok.status == 302 and ok.resp_cookies["admin_session"].value
      admin = fn c -> c |> Plug.Test.put_req_cookie("admin_session", ok.resp_cookies["admin_session"].value) |> with_origin() end

      dash = conn |> admin.() |> get("/admin")
      assert dash.status == 200 and body_of(dash) =~ "Ad server" and header(dash, "x-robots-tag") =~ "noindex"

      assert location(conn |> admin.() |> post("/admin/advertisers", %{name: "Ad Co", contact_email: ""})) =~ "Advertiser+added"
      adv = DB.value("SELECT id FROM advertisers WHERE name = 'Ad Co'")
      assert location(conn |> admin.() |> post("/admin/campaigns", %{advertiser_id: adv, name: "Spring", starts_on: "2026-09-01", ends_on: "2026-09-30", cpm_cents: "500", daily_cap: "0", total_cap: "0", titles: "%vp%, %head of%", industries: "SaaS", topics: ""})) =~ "draft"
      camp = DB.one("SELECT id, targeting FROM campaigns WHERE name = 'Spring'")
      assert camp.targeting["titles"] == ["%vp%", "%head of%"] and camp.targeting["topics"] == []
      assert (conn |> admin.() |> post("/admin/campaigns", %{advertiser_id: adv, name: "Backwards", starts_on: "2026-09-30", ends_on: "2026-09-01", cpm_cents: "0", daily_cap: "0", total_cap: "0"})).status == 400
      assert location(conn |> admin.() |> post("/admin/creatives", %{campaign_id: camp.id, slot: "banner", headline: "H", body: "B", cta: "", click_url: "https://a.example/x"})) =~ "Creative+added"
      assert (conn |> admin.() |> post("/admin/creatives", %{campaign_id: camp.id, slot: "banner", headline: "H", body: "B", click_url: "javascript:alert(1)"})).status == 400
      assert location(conn |> admin.() |> post("/admin/campaigns/#{camp.id}/status", %{status: "active"})) =~ "Campaign+active"
      assert DB.value("SELECT status FROM campaigns WHERE id = $1", [camp.id]) == "active"
      assert (conn |> admin.() |> post("/admin/logout", %{})).status == 302
    end
  end

  describe "webhooks" do
    test "mailgun refuses a bad signature; paypal refuses missing headers", %{conn: conn} do
      assert (conn |> post("/webhooks/mailgun", %{signature: %{timestamp: "1", token: "t", signature: String.duplicate("0", 64)}, "event-data": %{id: "1", event: "accepted"}})).status == 403
      assert (conn |> post("/webhooks/paypal", %{event_type: "BILLING.SUBSCRIPTION.ACTIVATED", resource: %{id: "I-1"}})).status == 401
    end
  end

  describe "the outbox and the worker" do
    test "enqueue dedupes, claim locks, retry backs off, maintenance reports", %{conn: _} do
      id = Outbox.enqueue(%{to_email: "a@b.test", kind: "login", payload: %{url: "u"}, dedupe_key: "k1"})
      assert id
      assert Outbox.enqueue(%{to_email: "a@b.test", kind: "login", payload: %{url: "u"}, dedupe_key: "k1"}) == nil
      job = Outbox.claim_job()
      assert job.id == id and job.status == "processing" and job.attempts == 1
      assert Outbox.claim_job() == nil
      Outbox.retry_later(job.id, job.attempts, "boom")
      assert DB.value("SELECT status FROM outbox WHERE id = $1", [id]) == "pending"
      assert DB.value("SELECT run_after > now() FROM outbox WHERE id = $1", [id])
      DB.execute("UPDATE outbox SET status='processing', locked_at = now() - interval '20 minutes' WHERE id = $1", [id])
      assert Outbox.requeue_stuck() == 1

      login = Worker.build_message(%{kind: "login", payload: %{"url" => "https://rnews1.test/login/x"}, contact_id: nil, tenant_id: nil})
      assert login.subject =~ "sign-in link" and login.html =~ "https://rnews1.test/login/x"
      campaign = Worker.build_message(%{kind: "campaign", payload: %{"name" => "Dana", "unsubscribeUrl" => "https://rnews1.test/u/t"}, contact_id: nil, tenant_id: nil})
      assert campaign.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click" and campaign.text =~ "Hi Dana,"
      assert_raise Worker.Unbuildable, fn -> Worker.build_message(%{kind: "mystery", payload: %{}, contact_id: nil, tenant_id: nil}) end

      assert Map.keys(Worker.maintenance()) |> Enum.sort() == [:briefs, :campaigns, :domains, :domains_failing, :exhausted, :expired, :requeued]
      assert Worker.schedule_digests(~U[2026-09-10 05:00:00Z]) == nil
    end

    test "the publish gate and the stakeholder roster", %{conn: conn} do
      %{tenant_id: id, tenant: tenant, story: story} = paid_tenant(stakeholders: 9)
      for path <- ["/feed/#{tenant.public_token}.xml", "/embed/#{tenant.public_token}", "/news/#{tenant.public_token}/#{story.id}"] do
        r = conn |> get(path)
        assert r.status == 409 and body_of(r) =~ "not published yet", path
      end
      s = session_for(id)
      assert (conn |> as_tenant(s) |> post("/api/subscribers", %{email: "tenth@acme.test", authorised: true})).status == 200
      assert (conn |> as_tenant(s) |> post("/api/subscribers", %{email: "tenth@acme.test", authorised: false})).status == 400
      assert (conn |> as_tenant(s) |> post("/api/subscribers", %{email: "tenth@acme.test", authorised: true})).status == 409
      assert (conn |> get("/embed/#{tenant.public_token}")).status == 200
      DB.execute("INSERT INTO topics(key, query, language) VALUES('t2','q','en')")
      theirs = DB.value("INSERT INTO stories(topic_key, issue_date, source_url, source_name, source_title, published_at, headline, standfirst, body, fingerprint) VALUES('t2','2026-09-10','https://example.com/t2','Times','T',now(),'Theirs','S','B','fp-t2') RETURNING id")
      assert (conn |> get("/news/#{tenant.public_token}/#{theirs}")).status == 404
      assert (conn |> get("/health")).status == 200
    end
  end
end
