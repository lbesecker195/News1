import Config

config :rnews1, Rnews1.Repo,
  url: System.get_env("DATABASE_URL", "postgres://localhost:5432/rnews1_phx"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :rnews1, Rnews1Web.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  # The app's own error pages, as in production: a 404 on a customer's host
  # should look the same in development as it will to their readers.
  debug_errors: false,
  secret_key_base: "REoI0MF6oF7lE0eA8rxPWVlPDRH/g9pYi/UDiFhIkr8akTOiOhjHbCAC8gSPIFn6",
  watchers: []

config :rnews1, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: false,
  enable_expensive_runtime_checks: true
