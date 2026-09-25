defmodule Rnews1Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :rnews1

  plug Plug.Static,
    at: "/",
    from: :rnews1,
    gzip: not code_reloading?,
    only: Rnews1Web.static_paths(),
    # Cache hard in production, not at all in development.
    cache_control_for_etags: if(code_reloading?, do: "no-cache", else: "public, max-age=3600")

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :rnews1
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    length: 1_000_000,
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug Rnews1Web.Plugs.RemoteIp
  plug Rnews1Web.Plugs.SecureHeaders
  plug Rnews1Web.Plugs.Host
  plug Rnews1Web.Dispatch
end
