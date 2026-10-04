defmodule Rnews1Web.NewsletterTest do
  @moduledoc """
  The newsletter on each publication's own site: the sign-up form, and the web
  version every emailed copy links to.
  """
  use Rnews1Web.ConnCase, async: false

  @host "fashionshowon.rnews1.test"
  @origin "https://fashionshowon.rnews1.test"

  setup do
    fashion =
      Rnews1.Publications.create(%{
        slug: "fashion",
        name: "FashionShowOn",
        hostname: @host,
        languages: ["en", "es"],
        sections: [%{name: "Runway", query: "runway"}]
      })

    for language <- ["en", "es"] do
      archive_story(%{
        publication_id: fashion.id,
        language: language,
        slug: "a-collection-arrived",
        translation_key: "fashion-1",
        category: "Runway",
        headline: "A collection arrived (#{language})"
      })
    end

    %{fashion: fashion}
  end

  defp fashion(conn), do: on_host(conn, @host)

  defp signup(conn, email, origin \\ @origin),
    do:
      conn
      |> fashion()
      |> put_req_header("origin", origin)
      |> post("/newsletter/subscribe", %{email: email})

  defp subscriptions, do: DB.value("SELECT count(*)::int FROM newsletter_subscriptions")

  test "the form is on the English listing, under the publication's own name, and nowhere else",
       %{conn: conn} do
    en = conn |> fashion() |> get("/en") |> body_of()
    assert en =~ ~s(action="/newsletter/subscribe")
    assert en =~ "Get FashionShowOn by email"
    refute en =~ "Confirm by email"

    refute conn |> fashion() |> get("/es") |> body_of() =~ "/newsletter/subscribe"
  end

  test "signing up subscribes the address to this publication, at once", %{
    conn: conn,
    fashion: fashion
  } do
    page = signup(conn, "reader@example.test")

    assert page.status == 200
    assert body_of(page) =~ "You&#39;re subscribed"
    assert header(page, "cache-control") =~ "no-store"

    assert [%{email: "reader@example.test", reason: :subscribed}] =
             Rnews1.Newsletter.audience(fashion)

    assert DB.value("SELECT count(*)::int FROM outbox") == 0
  end

  test "an opted-out address is told the same thing and stays out", %{conn: conn} do
    DB.execute("INSERT INTO contacts(email, opted_out_at) VALUES('gone@example.test', now())", [])

    page = signup(conn, "gone@example.test")
    assert page.status == 200 and body_of(page) =~ "You&#39;re subscribed"
    assert subscriptions() == 0
  end

  test "an address that is not one is sent back", %{conn: conn} do
    page = signup(conn, "nope")
    assert page.status == 400
    assert subscriptions() == 0
  end

  test "a post from another site is refused", %{conn: conn} do
    assert signup(conn, "reader@example.test", "https://evil.test").status == 403
    assert signup(conn, "reader@example.test", "https://www.rnews1.test").status == 403

    assert (conn
            |> fashion()
            |> post("/newsletter/subscribe", %{email: "reader@example.test"})).status == 403

    assert subscriptions() == 0
  end

  test "one requester can sign up five addresses an hour", %{conn: conn} do
    for i <- 1..5, do: assert(signup(conn, "reader#{i}@example.test").status == 200)

    limited = signup(conn, "reader6@example.test")
    assert limited.status == 429
    assert subscriptions() == 5
  end

  test "the web version is the latest edition, in the same template, without an unsubscribe link",
       %{conn: conn} do
    page = conn |> fashion() |> get("/newsletter")

    assert page.status == 200
    assert header(page, "x-robots-tag") == "noindex"
    assert body_of(page) =~ "A collection arrived (en)"
    refute body_of(page) =~ "A collection arrived (es)"
    assert body_of(page) =~ "This is the web version of the FashionShowOn newsletter"
    refute body_of(page) =~ "Unsubscribe"
  end

  test "a publication with nothing published has no web version yet", %{conn: conn} do
    Rnews1.Publications.create(%{
      slug: "empty",
      name: "Empty",
      hostname: "empty.rnews1.test",
      languages: ["en"],
      sections: []
    })

    assert (conn |> on_host("empty.rnews1.test") |> get("/newsletter")).status == 404
  end
end
