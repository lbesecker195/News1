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

  describe "a second publication" do
    setup do
      other =
        Rnews1.Publications.create(%{
          slug: "fashion",
          name: "FashionShowOn",
          hostname: "news.fashionshowon.test",
          languages: ["en"],
          sections: [%{name: "Runway", query: "runway shows collections"}]
        })

      archive_story(%{
        publication_id: other.id,
        language: "en",
        slug: "a-collection-arrived",
        translation_key: "fashion-1",
        category: "Runway",
        headline: "A collection arrived"
      })

      %{other: other}
    end

    defp fashion(conn), do: on_host(conn, "news.fashionshowon.test")

    test "serves its own stories on its own host, and neither site can see the other's", %{conn: conn} do
      mine = conn |> fashion() |> get("/en/runway/a-collection-arrived/#{@date}")
      assert mine.status == 200 and body_of(mine) =~ "A collection arrived"

      # The archive's story is not reachable on the fashion host, nor the reverse.
      assert (conn |> fashion() |> get(url("en"))).status == 404
      assert (conn |> www() |> get("/en/runway/a-collection-arrived/#{@date}")).status == 404

      index = body_of(conn |> fashion() |> get("/en"))
      assert index =~ "A collection arrived"
      refute index =~ "Headline in en"
    end

    test "builds canonical, hreflang and sitemap URLs on its own domain", %{conn: conn} do
      page = conn |> fashion() |> get("/en/runway/a-collection-arrived/#{@date}")
      assert body_of(page) =~ ~s(rel="canonical" href="https://news.fashionshowon.test/en/runway/a-collection-arrived/#{@date}")
      refute body_of(page) =~ "www.rnews1.test"

      map = body_of(conn |> fashion() |> get("/sitemap.xml"))
      assert map =~ "<loc>https://news.fashionshowon.test/sitemap-en.xml</loc>"
      refute map =~ "rnews1.test"

      assert body_of(conn |> fashion() |> get("/robots.txt")) =~ "Sitemap: https://news.fashionshowon.test/sitemap.xml"
    end

    test "publishes only the languages it runs", %{conn: conn} do
      # The archive runs Spanish; this publication does not, so the locale is
      # not merely empty here — it is not one of its URLs at all.
      assert (conn |> fashion() |> get("/es")).status == 404
      assert (conn |> fashion() |> get("/es/runway/a-collection-arrived/#{@date}")).status == 404
      assert (conn |> www() |> get("/es")).status == 200

      # And an unmatched Accept-Language lands on something real rather than a 404.
      root = conn |> fashion() |> put_req_header("accept-language", "es,ar;q=0.8") |> get("/")
      assert root.status == 302 and location(root) == "/en"
    end

    test "the TLS gate vouches for its hostname, which classify cannot recognise", %{conn: conn} do
      ok = conn |> get("/.well-known/tls-ask?domain=news.fashionshowon.test")
      assert ok.status == 200

      nope = conn |> get("/.well-known/tls-ask?domain=not-ours.test")
      assert nope.status == 404
    end
  end
end
