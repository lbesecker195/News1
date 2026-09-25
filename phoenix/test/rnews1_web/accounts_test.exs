defmodule Rnews1Web.AccountsTest do
  use Rnews1Web.ConnCase, async: false
  alias Rnews1.Accounts

  @email "owner@acme.test"
  @password "a-long-enough-one"

  defp account(opts \\ []) do
    id = new_tenant(@email)
    if opts[:password], do: Accounts.set_password(id, opts[:password])
    id
  end

  defp cookie(conn), do: conn.resp_cookies["session"]

  test "magic link: requested, confirmed by POST, single use", %{conn: conn} do
    r = conn |> with_origin() |> post("/api/login", %{email: "New@Acme.test"})
    assert json_of(r)["message"] =~ "Check your email"
    url = DB.value("SELECT payload->>'url' FROM outbox WHERE kind = 'login' ORDER BY created_at DESC LIMIT 1")
    token = url |> String.split("/") |> List.last()
    assert (conn |> get("/login/#{token}")).status == 200
    done = conn |> with_origin() |> post("/login/#{token}")
    assert done.status == 302 and location(done) == "/app" and cookie(done).http_only
    again = conn |> with_origin() |> post("/login/#{token}")
    assert again.status == 400
    assert (conn |> get("/login/not-a-token")).status == 400
  end

  test "password sign-in, identical failures, no forged posts", %{conn: conn} do
    account(password: @password)
    ok = conn |> with_origin() |> post("/api/login/password", %{email: @email, password: @password})
    assert ok.status == 200 and json_of(ok)["redirect"] == "/app" and cookie(ok)
    me = conn |> Plug.Test.put_req_cookie("session", cookie(ok).value) |> get("/api/me")
    assert me.status == 200

    answers =
      for body <- [%{email: @email, password: "wrong-but-long"}, %{email: "nobody@nowhere.test", password: @password}, %{email: @email, password: ""}] do
        r = conn |> with_origin() |> post("/api/login/password", body)
        assert r.status == 401 and cookie(r) == nil
        json_of(r)["error"]
      end

    assert length(Enum.uniq(answers)) == 1
    forged = conn |> put_req_header("origin", "https://evil.test") |> post("/api/login/password", %{email: @email, password: @password})
    assert forged.status == 403
    assert (conn |> with_origin() |> post("/api/login", %{email: @email})).status == 200
  end

  test "an account with no password refuses any password" , %{conn: conn} do
    account()
    for p <- ["", @password] do
      assert (conn |> with_origin() |> post("/api/login/password", %{email: @email, password: p})).status == 401
    end
  end

  test "set from a session, change with the current one, other sessions end, remove", %{conn: conn} do
    id = account()
    mine = session_for(id)
    refute (conn |> as_tenant(mine) |> get("/api/me") |> json_of())["password"]["set"]
    assert (conn |> as_tenant(mine) |> post("/api/password", %{password: "short"})).status == 400
    set = conn |> as_tenant(mine) |> post("/api/password", %{password: @password})
    assert set.status == 200 and json_of(set)["password"]["set"]
    assert (conn |> as_tenant(mine) |> get("/api/me") |> json_of())["password"]["setAt"]

    elsewhere = session_for(id)
    assert (conn |> as_tenant(mine) |> post("/api/password", %{password: "another-good-one", current: "not-it"})).status == 401
    changed = conn |> as_tenant(mine) |> post("/api/password", %{password: "another-good-one", current: @password})
    assert changed.status == 200 and json_of(changed)["message"] =~ "signed out"
    assert (conn |> as_tenant(mine) |> get("/api/me")).status == 200
    assert (conn |> as_tenant(elsewhere) |> get("/api/me")).status == 401
    assert (conn |> with_origin() |> post("/api/login/password", %{email: @email, password: @password})).status == 401

    assert (conn |> as_tenant(mine) |> delete("/api/password", %{current: "wrong-but-long"})).status == 401
    removed = conn |> as_tenant(mine) |> delete("/api/password", %{current: "another-good-one"})
    assert removed.status == 200 and json_of(removed)["password"]["set"] == false
    assert (conn |> with_origin() |> post("/api/password", %{password: @password})).status == 401, "a stranger cannot set one"
  end

  test "guessing is rate limited; the link still works; the plaintext is never stored", %{conn: conn} do
    id = account(password: @password)
    statuses = for _ <- 1..12, do: (conn |> with_origin() |> post("/api/login/password", %{email: @email, password: "wrong-but-long"})).status
    assert 429 in statuses
    assert (conn |> with_origin() |> post("/api/login/password", %{email: @email, password: @password})).status == 429
    Rnews1Web.RateLimit.reset_all()
    assert (conn |> with_origin() |> post("/api/login", %{email: @email})).status == 200
    stored = DB.value("SELECT password_hash FROM tenants WHERE id = $1", [id])
    assert String.starts_with?(stored, "$argon2") and not (stored =~ @password)
  end

  test "logout ends the session", %{conn: conn} do
    id = account()
    s = session_for(id)
    assert (conn |> as_tenant(s) |> post("/api/logout", %{})).status == 200
    assert (conn |> as_tenant(s) |> get("/api/me")).status == 401
    assert (conn |> get("/app")).status == 302
  end
end
