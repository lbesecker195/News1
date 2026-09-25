defmodule Rnews1Web.Plugs.Auth do
  @moduledoc "Tenant sessions (cookie `session`) and staff sessions (cookie `admin_session`, path /admin)."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias Rnews1.{Accounts, Admins}
  alias Rnews1.Util.Ids

  @session "session"
  @admin "admin_session"

  def session_cookie, do: @session
  def admin_cookie, do: @admin

  defp resolve_tenant(conn) do
    conn = fetch_cookies(conn)

    case conn.req_cookies[@session] do
      value when is_binary(value) and value != "" -> {conn, Accounts.find_tenant_by_session(Ids.hash(value))}
      _ -> {conn, nil}
    end
  end

  @doc "JSON endpoints: an unauthenticated caller gets a 401 it can act on."
  def require_auth(conn, _opts) do
    case resolve_tenant(conn) do
      {conn, nil} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Sign in first."}))
        |> halt()

      {conn, tenant} ->
        assign(conn, :tenant, tenant)
    end
  end

  @doc "Page routes: a signed-out visitor is sent to the marketing page."
  def require_auth_page(conn, _opts) do
    case resolve_tenant(conn) do
      {conn, nil} -> conn |> redirect(to: "/") |> halt()
      {conn, tenant} -> assign(conn, :tenant, tenant)
    end
  end

  @doc "Never blocks; sets signed_in so shared chrome can offer the right link."
  def attach_session(conn, _opts) do
    case resolve_tenant(conn) do
      {conn, nil} -> assign(conn, :signed_in, false)
      {conn, tenant} -> conn |> assign(:tenant, tenant) |> assign(:signed_in, true)
    end
  rescue
    _ -> assign(conn, :signed_in, false)
  end

  def require_admin(conn, _opts) do
    conn = fetch_cookies(conn)

    admin =
      case conn.req_cookies[@admin] do
        value when is_binary(value) and value != "" -> Admins.find_by_session(Ids.hash(value))
        _ -> nil
      end

    case admin do
      nil -> conn |> redirect(to: "/admin/login") |> halt()
      admin -> assign(conn, :admin, admin)
    end
  end
end
