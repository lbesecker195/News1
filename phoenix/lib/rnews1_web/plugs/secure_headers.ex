defmodule Rnews1Web.Plugs.SecureHeaders do
  @moduledoc """
  What helmet set: a strict CSP, no framing, strict referrer, no sniffing.

  The only third party a page may load from is the analytics tracker, and
  only when one is configured (see `Rnews1Web.Analytics`): its script and
  the beacons it sends home.
  """
  @behaviour Plug
  import Plug.Conn
  alias Rnews1.Env
  alias Rnews1Web.Analytics

  @directives [
    {"default-src", ["'self'"]},
    {"script-src", ["'self'"]},
    {"style-src", ["'self'", "'unsafe-inline'"]},
    {"img-src", ["'self'", "data:"]},
    {"font-src", ["'self'"]},
    {"connect-src", ["'self'"]},
    {"frame-src", ["'self'"]},
    {"frame-ancestors", ["'self'"]},
    {"form-action", ["'self'"]},
    {"base-uri", ["'self'"]},
    {"object-src", ["'none'"]}
  ]
  @tracker_directives ["script-src", "connect-src"]
  @site_directives ["frame-src"]

  def csp do
    extra = if Analytics.enabled?(), do: [Analytics.origin()], else: []
    sites = [sites_wildcard()]

    @directives
    |> Enum.map(fn
      {name, sources} when name in @tracker_directives ->
        Enum.join([name | sources ++ extra], " ")

      {name, sources} when name in @site_directives ->
        Enum.join([name | sources ++ sites], " ")

      {name, sources} ->
        Enum.join([name | sources], " ")
    end)
    |> Enum.join("; ")
  end

  # The dashboard frames a customer's own site so they can see what readers get.
  # Every such site is served from the platform domain — a custom domain is only
  # ever an alias onto one — so the frame is pointed at the platform origin and
  # one wildcard covers every tenant, rather than opening framing to the web.
  defp sites_wildcard do
    uri = Env.app_uri()
    port = if uri.port in [nil, 80, 443], do: "", else: ":#{uri.port}"

    "#{uri.scheme}://*.#{Env.sites_domain()}#{port}"
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
