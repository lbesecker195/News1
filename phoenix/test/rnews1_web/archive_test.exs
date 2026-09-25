defmodule Rnews1Web.ArchiveTest do
  use Rnews1Web.ConnCase, async: false

  @languages ~w(en es ar zh)
  @slug "a-thing-that-happened"
  @date "2026-08-29"

  setup do
    for l <- @languages, do: archive_story(%{language: l, headline: "Headline in #{l}"})
    :ok
  end

  defp www(conn), do: on_host(conn, "www.rnews1.test")
  defp url(l, topic \\ "usa", slug \\ @slug, date \\ @date), do: "/#{l}/#{topic}/#{slug}/#{date}"

  test "serves the canonical URL with the authored date, redirects the rest", %{conn: conn} do
    page = conn |> www() |> get(url("en"))
    assert page.status == 200 and body_of(page) =~ "Headline in en" and body_of(page) =~ ~s(<html lang="en" dir="ltr">)
    utc = conn |> www() |> get(url("en", "usa", @slug, "2026-08-30"))
    assert utc.status == 301 and location(utc) =~ ~r/2026-08-29$/
    undated = conn |> www() |> get("/en/usa/#{@slug}")
    # The old Hugo site's form: no date, trailing slash.
    hugo = conn |> www() |> get("/en/usa/#{@slug}/")
    assert hugo.status == 301 and location(hugo) =~ ~r/\/en\/usa\/#{@slug}\/#{@date}$/
    assert undated.status == 301 and location(undated) =~ ~r/\/en\/usa\/#{@slug}\/#{@date}$/
    stale = conn |> www() |> get(url("en", "world"))
    assert stale.status == 301 and location(stale) =~ "/en/usa/"
    for path <- ["/xx", "/xx/usa", "/xx/usa/#{@slug}/#{@date}"] do
      assert (conn |> www() |> get(path)).status == 404
    end
  end

  test "every language is its own page, declared to the others", %{conn: conn} do
    for l <- @languages do
      page = conn |> www() |> get(url(l))
      assert page.status == 200 and body_of(page) =~ "Headline in #{l}"
    end
    html = body_of(conn |> www() |> get(url("es")))
    for l <- @languages do
      assert html =~ ~s(<link rel="alternate" hreflang="#{l}" href="https://www.rnews1.test/#{l}/usa/#{@slug}/#{@date}">)
    end
    assert html =~ ~r/hreflang="x-default"[^>]*\/en\/usa\//
    assert body_of(conn |> www() |> get(url("ar"))) =~ ~s(<link rel="canonical" href="https://www.rnews1.test/ar/usa/#{@slug}/#{@date}">)
    assert body_of(conn |> www() |> get(url("ar"))) =~ ~s(<html lang="ar" dir="rtl">)
    refute body_of(conn |> www() |> get(url("en"))) =~ "noindex"
    assert body_of(conn |> www() |> get(url("en"))) =~ ~r/\d+ min read/
    assert body_of(conn |> www() |> get(url("en"))) =~ "Español"
  end

  test "indexes, sections, markdown escaping and continue-reading", %{conn: conn} do
    assert body_of(conn |> www() |> get("/en")) =~ "Headline in en"
    assert (conn |> www() |> get("/en/usa")).status == 200
    assert (conn |> www() |> get("/en/nothing-here")).status == 404
    DB.execute("UPDATE stories SET body = $1 WHERE language = 'en'", ["A <script>alert(1)</script> line with **bold**."])
    html = body_of(conn |> www() |> get(url("en")))
    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;" and html =~ "<strong>bold</strong>"
    archive_story(%{slug: "another-piece", translation_key: "group-2", headline: "A second story"})
    html = body_of(conn |> www() |> get(url("en")))
    assert html =~ "Continue reading" and html =~ "A second story" and html =~ ~r/\/en\/usa\/another-piece\//
  end

  test "the app host redirects archive paths to www and leaves the app alone", %{conn: conn} do
    for path <- [url("en"), "/en/usa/#{@slug}", "/en/usa", "/en"] do
      r = conn |> get(path)
      assert r.status == 301 and location(r) == "https://www.rnews1.test#{path}", path
    end
    assert (conn |> get("/xx/usa")).status == 404
    for {path, status} <- [{"/", 200}, {"/privacy", 200}, {"/terms", 200}, {"/login", 200}, {"/robots.txt", 200}] do
      assert (conn |> get(path)).status == status
    end
    for path <- ["/app", "/login", "/api/me", "/privacy"] do
      assert (conn |> www() |> get(path)).status == 404
    end
  end

  test "www's root picks the reader's language; sitemaps are one per language with hreflang", %{conn: conn} do
    plain = conn |> www() |> get("/")
    assert plain.status == 302 and location(plain) == "/en" and header(plain, "vary") =~ "Accept-Language"
    assert location(conn |> www() |> put_req_header("accept-language", "es-MX,es;q=0.9,en;q=0.5") |> get("/")) == "/es"
    index = body_of(conn |> www() |> get("/sitemap.xml"))
    assert index =~ "<sitemapindex"
    for l <- @languages do
      assert index =~ "<loc>https://www.rnews1.test/sitemap-#{l}.xml</loc>"
    end
    refute index =~ "sitemap-la.xml"
    assert (conn |> www() |> get("/sitemap-xx.xml")).status == 404
    en = body_of(conn |> www() |> get("/sitemap-en.xml"))
    assert en =~ "<loc>https://www.rnews1.test/en/usa/#{@slug}/#{@date}</loc>"
    refute en =~ "<loc>https://www.rnews1.test/es/usa/"
    for l <- @languages do
      assert en =~ ~s(<xhtml:link rel="alternate" hreflang="#{l}" href="https://www.rnews1.test/#{l}/usa/#{@slug}/#{@date}"/>)
    end
    assert en =~ ~s(hreflang="x-default" href="https://www.rnews1.test/en/usa/#{@slug}/#{@date}")
    assert body_of(conn |> www() |> get("/robots.txt")) =~ "Sitemap: https://www.rnews1.test/sitemap.xml"
    refute body_of(conn |> get("/sitemap.xml")) =~ "/usa/#{@slug}/"
  end
end
