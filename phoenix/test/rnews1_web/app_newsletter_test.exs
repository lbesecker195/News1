defmodule Rnews1Web.AppNewsletterTest do
  @moduledoc """
  A news site's newsletter list, seen from the account that owns the site.
  """
  use Rnews1Web.ConnCase, async: false
  alias Rnews1.{Newsletter, Publications}

  setup do
    %{tenant_id: tenant_id} = paid_tenant(email: "owner@acme.test")

    fashion =
      Publications.create(%{
        slug: "fashion",
        name: "FashionShowOn",
        hostname: "fashionshowon.rnews1.test",
        languages: ["en"],
        sections: [%{name: "Runway", query: "runway"}]
      })

    Publications.adopt("fashion", tenant_id)

    %{
      tenant_id: tenant_id,
      session: session_for(tenant_id),
      fashion: Publications.find_by_slug("fashion")
    }
  end

  defp get_list(conn, session, slug \\ "fashion"),
    do: conn |> as_tenant(session) |> get("/api/newsletter/#{slug}")

  test "lists the site's readers, newest first, with the day they joined", %{
    conn: conn,
    session: session,
    fashion: fashion
  } do
    Newsletter.subscribe(fashion, "first@example.test")
    Newsletter.subscribe(fashion, "second@example.test")

    # Everything in one test transaction shares `now()`, so the older sign-up
    # has to be made older for the ordering to mean anything.
    DB.execute(
      "UPDATE newsletter_subscriptions s SET created_at = now() - interval '1 day' FROM contacts c WHERE c.id = s.contact_id AND c.email = 'first@example.test'",
      []
    )

    body = get_list(conn, session) |> json_of()

    assert body["name"] == "FashionShowOn"

    assert [
             %{"email" => "second@example.test", "suppressed" => false},
             %{"email" => "first@example.test"}
           ] = body["subscribers"]

    assert body["receiving"] == 2
    assert Enum.all?(body["subscribers"], &(&1["joined"] =~ ~r/^\d{4}-\d{2}-\d{2}$/))
    assert body["webUrl"] == "https://fashionshowon.rnews1.test/newsletter"
    assert body["signupUrl"] == "https://fashionshowon.rnews1.test/en"
  end

  test "flags a reader who has since opted out, and leaves them out of the count", %{
    conn: conn,
    session: session,
    fashion: fashion
  } do
    Newsletter.subscribe(fashion, "gone@example.test")
    Newsletter.subscribe(fashion, "here@example.test")
    DB.execute("UPDATE contacts SET opted_out_at = now() WHERE email = 'gone@example.test'", [])

    body = get_list(conn, session) |> json_of()

    assert body["receiving"] == 1
    assert length(body["subscribers"]) == 2
    assert Enum.find(body["subscribers"], &(&1["email"] == "gone@example.test"))["suppressed"]
  end

  test "says whether an edition is going out at all", %{conn: conn, session: session} do
    assert get_list(conn, session) |> json_of() |> Map.get("sendingHour") == nil

    previous = Application.get_env(:rnews1, :env)
    Application.put_env(:rnews1, :env, Keyword.put(previous, :edition_hour, "14"))
    on_exit(fn -> Application.put_env(:rnews1, :env, previous) end)

    assert get_list(conn, session) |> json_of() |> Map.get("sendingHour") == 14
  end

  test "lists the editions the site has sent", %{conn: conn, session: session, fashion: fashion} do
    DB.execute(
      "INSERT INTO edition_runs(publication_id, edition_date, recipients) VALUES($1,'2026-09-10'::date,3),($1,'2026-09-11'::date,4)",
      [fashion.id]
    )

    assert [
             %{"date" => "2026-09-11", "recipients" => 4},
             %{"date" => "2026-09-10", "recipients" => 3}
           ] =
             get_list(conn, session) |> json_of() |> Map.get("editions")
  end

  test "removing a reader takes them off this site only, and never opts them out", %{
    conn: conn,
    session: session,
    fashion: fashion
  } do
    archive = publication()
    Newsletter.subscribe(fashion, "reader@example.test")
    Newsletter.subscribe(archive, "reader@example.test")

    removed =
      conn
      |> as_tenant(session)
      |> delete("/api/newsletter/fashion/subscriber", %{email: "reader@example.test"})

    assert removed.status == 200 and json_of(removed)["removed"]
    assert get_list(conn, session) |> json_of() |> Map.get("subscribers") == []
    assert [%{email: "reader@example.test"}] = Newsletter.audience(archive)

    assert DB.value(
             "SELECT count(*)::int FROM contacts WHERE email = 'reader@example.test' AND opted_out_at IS NULL"
           ) == 1
  end

  test "a site the account does not own is not there to be read", %{conn: conn, session: session} do
    Publications.create(%{
      slug: "someone-else",
      name: "Someone Else",
      hostname: "someone-else.rnews1.test",
      languages: ["en"],
      sections: []
    })

    assert get_list(conn, session, "someone-else").status == 404
    assert get_list(conn, session, "no-such-site").status == 404

    assert (conn
            |> as_tenant(session)
            |> delete("/api/newsletter/someone-else/subscriber", %{email: "a@b.test"})).status ==
             404
  end

  test "signing in is required", %{conn: conn} do
    assert (conn |> get("/api/newsletter/fashion")).status == 401
  end
end
