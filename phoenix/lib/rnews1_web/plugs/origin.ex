defmodule Rnews1Web.Plugs.Origin do
  @moduledoc """
  The CSRF defence. Browsers always send Origin on cross-site state-changing
  requests, and the session cookie is SameSite=Lax, so an exact match against
  the app's own origin is enough without a token round trip.
  """
  import Plug.Conn
  alias Rnews1.Env

  def require_same_origin(conn, _opts) do
    if get_req_header(conn, "origin") == [Env.app_origin()] do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "Invalid request origin."}))
      |> halt()
    end
  end

  def protect_mutations(conn, opts) do
    if conn.method in ["GET", "HEAD", "OPTIONS"], do: conn, else: require_same_origin(conn, opts)
  end
end
