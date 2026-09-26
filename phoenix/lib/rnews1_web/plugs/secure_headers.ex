defmodule Rnews1Web.Plugs.SecureHeaders do
  @moduledoc """
  What helmet set: a strict CSP, no framing, strict referrer, no sniffing.

  The only third party a page may load from is the analytics tracker, and
  only when one is configured (see `Rnews1Web.Analytics`): its script and
  the beacons it sends home.
  """
  @behaviour Plug
  import Plug.Conn
  alias Rnews1Web.Analytics

  @directives [
    {"default-src", ["'self'"]},
    {"script-src", ["'self'"]},
    {"style-src", ["'self'", "'unsafe-inline'"]},
    {"img-src", ["'self'", "data:"]},
    {"font-src", ["'self'"]},
    {"connect-src", ["'self'"]},
    {"frame-ancestors", ["'self'"]},
    {"form-action", ["'self'"]},
    {"base-uri", ["'self'"]},
    {"object-src", ["'none'"]}
  ]
  @tracker_directives ["script-src", "connect-src"]

  def csp do
    extra = if Analytics.enabled?(), do: [Analytics.origin()], else: []

    @directives
    |> Enum.map(fn
      {name, sources} when name in @tracker_directives ->
        Enum.join([name | sources ++ extra], " ")

      {name, sources} ->
        Enum.join([name | sources], " ")
    end)
    |> Enum.join("; ")
  end

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", csp())
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("cross-origin-resource-policy", "cross-origin")
  end
end
