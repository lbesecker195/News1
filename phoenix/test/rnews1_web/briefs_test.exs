defmodule Rnews1Web.BriefsTest do
  use Rnews1Web.ConnCase, async: false
  alias Rnews1.{BriefPage, Briefs, Content, DB}

  setup do
    original = File.read!(Content.file())
    on_exit(fn -> File.write!(Content.file(), original); Content.reset_cache() end)
    Content.reset_cache()
    :ok
  end

  defp with_content(fun) do
    config = Content.file() |> File.read!() |> Jason.decode!()
    File.write!(Content.file(), Jason.encode!(fun.(config), pretty: true))
    Content.reset_cache()
  end

  defp seed(story_count \\ 3) do
    DB.execute("INSERT INTO topics(key, query, language) VALUES('t1','q','en')")
    tenant_id = DB.value("INSERT INTO tenants(owner_email, name, industry, keywords, billing_status, subdomain, topic_key) VALUES('owner@acme.test','Acme Robotics','Industrial robotics','[\"warehouse automation\",\"grippers\"]','active','acme','t1') RETURNING id")
    ids = for n <- 0..(story_count - 1) do
      DB.value("INSERT INTO stories(topic_key, issue_date, source_url, source_name, source_title, published_at, headline, standfirst, body, fingerprint) VALUES('t1','2026-09-10',$1,'The Example Times',$2,now(),$2,'A standfirst.','## Heading\n\nA **paragraph**.',$3) RETURNING id", ["https://example.com/s#{n}", "Story number #{n}", "fp-#{n}"])
    end
    %{brief_id: Briefs.create(%{tenant_id: tenant_id, html: "<p>the emailed version</p>", story_ids: ids, issue_date: "2026-09-10"}), story_ids: ids, tenant_id: tenant_id}
  end

  test "renders the blocks content.json lists, in order, with a hero and a grid", %{conn: conn} do
    %{brief_id: id} = seed()
    with_content(fn c -> put_in(c, ["report", "blocks"], [%{"type" => "masthead"}, %{"type" => "summary"}, %{"type" => "note", "title" => "Note", "body" => "A note."}, %{"type" => "stories", "limit" => 8}, %{"type" => "footer"}]) end)
    page = conn |> get("/brief/#{id}")
    assert page.status == 200
    html = body_of(page)
    positions = for name <- ~w(masthead summary note hero), do: :binary.match(html, ~s(class="#{name}")) |> elem(0)
    assert positions == Enum.sort(positions)
    assert length(Regex.scan(~r/class="hero"/, html)) == 1
    assert length(Regex.scan(~r/class="item"/, html)) == 2
    assert html =~ "Story number 0" and html =~ "A standfirst." and html =~ "Read the full story"
    assert html =~ ~s(<p class="teaser">A standfirst…</p>)
    refute html =~ "<strong>paragraph</strong>"
    assert html =~ ~s(<a class="hero" href="https://example.com/s0">)
    assert html =~ ~s(<a class="item" href="https://example.com/s1">)
    assert html =~ ~r/@page\s*\{[^}]*size: A4/s and html =~ "margin: 16mm" and html =~ "print-color-adjust: exact"
    refute html =~ ~s(<link rel="stylesheet") 
    refute html =~ "<script"
  end

  test "config drives copy and layout, and bad config falls back", %{conn: conn} do
    %{brief_id: id} = seed()
    with_content(fn c -> c |> put_in(["report", "title"], "Morning Brief") |> put_in(["report", "theme", "accent"], "#0b7a5a") |> put_in(["report", "print", "pageSize"], "Letter") |> put_in(["report", "blocks"], [%{"type" => "masthead"}, %{"type" => "stories", "limit" => 2, "hero" => false, "columns" => 1}, %{"type" => "footer"}]) end)
    html = body_of(conn |> get("/brief/#{id}"))
    assert html =~ "<h1>Morning Brief</h1>" and html =~ "--accent: #0b7a5a" and html =~ "size: Letter" and html =~ "repeat(1, minmax"
    assert length(Regex.scan(~r/class="item"/, html)) == 2
    refute html =~ ~s(class="hero")

    with_content(fn c -> put_in(c, ["report", "theme", "accent"], "red; } body { display: none } .x {") end)
    html = body_of(conn |> get("/brief/#{id}"))
    assert html =~ "--accent: #1a4fd6" and not (html =~ "display: none")

    File.write!(Content.file(), "{ not json,,, "); Content.reset_cache()
    broken = conn |> get("/brief/#{id}")
    assert broken.status == 200 and body_of(broken) =~ "<h1>Daily Briefing</h1>"

    DB.execute("UPDATE tenants SET name = $1", ["<script>alert(1)</script>"])
    Content.reset_cache()
    assert body_of(conn |> get("/brief/#{id}")) =~ "&lt;script&gt;"
  end

  test "the emailed version stays available; links go to the tenant's site once published", %{conn: conn} do
    %{brief_id: id} = seed()
    assert body_of(conn |> get("/brief/#{id}/email")) == "<p>the emailed version</p>"
    record = Briefs.find_unexpired(id)
    assert BriefPage.present(record).hero.url == "https://example.com/s0"
    assert BriefPage.present(Map.put(record, :stakeholder_count, 10)).hero.url == "https://acme.rnews1.test/news/#{hd(record.story_ids)}"
  end

  test "a custom report links archive stories to www and explains its sections", %{conn: conn} do
    row = archive_story(%{slug: "a-piece", translation_key: "g1", category: "Compliance", headline: "An archive piece", standfirst: "Written by us. Read it here.", origin: "editorial"})
    id = Briefs.create(%{html: "", story_ids: [row.id], issue_date: "2026-09-10", meta: %{reader: %{title: "VP Compliance", company: "Northgate"}, sections: [%{name: "Compliance", why: "Rules land on your desk first."}]}})
    html = body_of(conn |> get("/brief/#{id}"))
    assert html =~ ~s(<a class="hero" href="https://www.rnews1.test/en/compliance/a-piece/2026-08-29">)
    assert html =~ "Rules land on your desk first." and html =~ ~s(class="impact") and html =~ "VP Compliance, Northgate"
  end

  test "a tenant's briefs exist only on their host", %{conn: conn} do
    mine = paid_tenant(stakeholders: 10)
    paid_tenant(email: "owner@rival.test", name: "Rival Corp", stakeholders: 10)
    id = Briefs.create(%{tenant_id: mine.tenant_id, html: "<p>mail</p>", story_ids: [mine.story.id], issue_date: "2026-09-10"})
    assert (conn |> on_host("acme.rnews1.test") |> get("/brief/#{id}")).status == 200
    assert (conn |> on_host("rival.rnews1.test") |> get("/brief/#{id}")).status == 404
    assert (conn |> get("/brief/#{id}")).status == 200
  end

  @tag :chrome
  test "prints to one PDF page on demand, links intact", %{conn: conn} do
    %{brief_id: id} = seed()
    r = conn |> get("/pdf/#{id}")
    assert r.status == 200 and header(r, "content-type") =~ "application/pdf"
    assert String.starts_with?(r.resp_body, "%PDF-") and Rnews1.PDF.page_count(r.resp_body) == 1
    assert r.resp_body =~ "/URI (https://example.com/s0)"
    assert DB.value("SELECT has_pdf FROM briefs WHERE id = $1", [id])
  end
end
