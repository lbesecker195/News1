defmodule Rnews1Web.AnalyticsTest do
  use Rnews1Web.ConnCase, async: false
  import Rnews1.Fixtures
  alias Rnews1.Subscribers
  alias Rnews1Web.Analytics

  @published Subscribers.required_stakeholders()
  @tracker ~s(src="https://seriouslysimpleanalytics.com/wa.js")

  defp with_account(id) do
    previous = Application.get_env(:rnews1, :env, [])
    Application.put_env(:rnews1, :env, Keyword.put(previous, :ssa_account_id, id))
    on_exit(fn -> Application.put_env(:rnews1, :env, previous) end)
  end

  test "the project is the host's subdomain: app, the archive's label, a tenant's label on both their hosts" do
    assert Analytics.project(%{}) == "app"
    assert Analytics.project(%{archive: true}) == "www"

    tenant = %{subdomain: "acme", custom_hostname: "news.acme.test"}
    assert Analytics.project(%{site: %{host: "acme.rnews1.test", tenant: tenant}}) == "acme"
    assert Analytics.project(%{site: %{host: "news.acme.test", tenant: tenant}}) == "acme"

    assert Analytics.project(%{site: %{host: "nobody.rnews1.test", tenant: nil}}) == "nobody"

    assert Analytics.project(%{site: %{host: "stray.example.test", tenant: nil}}) ==
             "stray.example.test"
  end

  test "nothing is emitted, and the CSP stays closed, until an account is configured", %{
    conn: conn
  } do
    r = get(conn, "/")
    assert r.status == 200
    refute body_of(r) =~ "wa.js"
    refute header(r, "content-security-policy") =~ "seriouslysimpleanalytics"
    assert Analytics.tag(%{archive: true}) == ""
  end

  test "the tag is on the app, the archive and customer sites with the host's project; the CSP admits it",
       %{conn: conn} do
    with_account("acct_test123")
    %{story: story} = paid_tenant(stakeholders: @published)
    archive_story(%{language: "en", headline: "Headline in en"})

    app = get(conn, "/")

    assert body_of(app) =~
             ~s(#{@tracker} data-site="acct_test123" data-project="app" data-forms="false" defer)

    csp = header(app, "content-security-policy")
    assert csp =~ "script-src 'self' https://seriouslysimpleanalytics.com"
    assert csp =~ "connect-src 'self' https://seriouslysimpleanalytics.com"
    refute csp =~ "img-src 'self' data: https://"

    site = conn |> on_host("acme.rnews1.test") |> get("/news/#{story.id}")
    assert site.status == 200
    assert body_of(site) =~ ~s(#{@tracker} data-site="acct_test123" data-project="acme")

    archive = conn |> on_host("www.rnews1.test") |> get("/en")
    assert archive.status == 200
    assert body_of(archive) =~ ~s(data-project="www")

    # A page can still opt out, and the brief page gets the same tag as a string.
    assert Analytics.for_page(%{track: false}) == nil

    assert Analytics.tag(%{site: %{host: "news.acme.test", tenant: %{subdomain: "acme"}}}) =~
             ~s(data-project="acme" data-forms="false")

    assert Analytics.tag(%{site: %{host: "x.rnews1.test", tenant: %{subdomain: ~s(a"b)}}}) =~
             ~s(data-project="a&quot;b")
  end
end
