defmodule Rnews1Web.AuthController do
  use Rnews1Web, :controller
  alias Rnews1.{Accounts, Content, Env}
  alias Rnews1.Util.{Ids, Password}
  alias Rnews1Web.Plugs.{Auth, RateLimit}
  import Rnews1Web.Validation

  plug RateLimit, :login when action in [:request_login]
  plug RateLimit, :password when action in [:password_login]
  plug RateLimit, :login_complete when action in [:complete_login]
  plug :require_same_origin_for_complete when action in [:complete_login]
  plug :put_brand when action in [:show_login]

  defp put_brand(conn, _), do: conn |> assign(:brand, Content.brand()) |> assign(:app_origin, Env.app_origin())
  defp require_same_origin_for_complete(conn, _), do: Rnews1Web.Plugs.Origin.require_same_origin(conn, [])

  def request_login(conn, _) do
    email = email!(body(conn)["email"])
    secret = Ids.token()
    Accounts.create_login(%{email: email, token_hash: Ids.hash(secret), url: "#{Env.app_origin()}/login/#{secret}"})
    # Deliberately the same answer whether or not the address is known.
    json(conn, %{message: "Check your email for a sign-in link."})
  end

  @doc "An interstitial: mail scanners follow links, and a GET that signed in would burn the token."
  def show_login(conn, %{"token" => token}) do
    if not Ids.login_token?(token), do: fail!(400, "Invalid sign-in link.")
    conn |> no_store() |> page(title: "Confirm sign in") |> render(:login, login_token: token)
  end

  def complete_login(conn, %{"token" => token}) do
    if not Ids.login_token?(token), do: fail!(400, "Invalid sign-in link.")
    secret = Ids.token()

    case Accounts.consume_login_and_create_session(%{login_hash: Ids.hash(token), session_hash: Ids.hash(secret)}) do
      nil -> fail!(400, "Link expired or already used.")
      _tenant_id -> conn |> put_resp_cookie(Auth.session_cookie(), secret, cookie_opts(max_age: 14 * 86_400)) |> redirect(to: "/app")
    end
  end

  def password_login(conn, _) do
    email = email!(body(conn)["email"])
    password = to_string(body(conn)["password"] || "")

    case Accounts.authenticate_tenant(email, password) do
      nil ->
        fail!(401, "Those details were not recognised.")

      tenant ->
        secret = Ids.token()
        Accounts.create_session_for(tenant.id, Ids.hash(secret))

        conn
        |> put_resp_cookie(Auth.session_cookie(), secret, cookie_opts(max_age: Accounts.session_days() * 86_400))
        |> json(%{message: "Signed in.", redirect: "/app"})
    end
  end

  def set_password(conn, _) do
    tenant = conn.assigns.tenant
    password = password!(body(conn)["password"])
    state = Accounts.has_password(tenant.id)

    if state.set do
      current = to_string(body(conn)["current"] || "")
      if is_nil(Accounts.authenticate_tenant(tenant.owner_email, current)), do: fail!(401, "That is not your current password.")
    end

    Accounts.set_password(tenant.id, password, Ids.hash(current_session(conn)))

    json(conn, %{
      message: if(state.set, do: "Password changed. Any other sessions have been signed out.", else: "Password set. You can now sign in with it."),
      password: %{set: true}
    })
  end

  def remove_password(conn, _) do
    tenant = conn.assigns.tenant
    if not Accounts.has_password(tenant.id).set, do: fail!(400, "No password is set on this account.")
    current = to_string(body(conn)["current"] || "")
    if is_nil(Accounts.authenticate_tenant(tenant.owner_email, current)), do: fail!(401, "That is not your current password.")
    Accounts.set_password(tenant.id, nil, Ids.hash(current_session(conn)))
    json(conn, %{message: "Password removed. Sign in by emailed link from now on.", password: %{set: false}})
  end

  def logout(conn, _) do
    Accounts.delete_session(Ids.hash(current_session(conn)))
    conn |> delete_resp_cookie(Auth.session_cookie(), cookie_opts()) |> json(%{ok: true})
  end

  defp current_session(conn), do: fetch_cookies(conn).req_cookies[Auth.session_cookie()] || ""

  def password_min_length, do: Password.min_length()

  def password!(value) do
    value = to_string(value || "")

    cond do
      String.length(value) < Password.min_length() -> fail!(400, "Use at least #{Password.min_length()} characters.")
      String.length(value) > 200 -> fail!(400, "That password is too long.")
      true -> value
    end
  end
end

defmodule Rnews1Web.AuthHTML do
  use Rnews1Web, :html
  embed_templates "auth_html/*"
end
