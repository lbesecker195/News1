import Config

config :rnews1,
  ecto_repos: [Rnews1.Repo],
  generators: [timestamp_type: :utc_datetime]

# A separate bookkeeping table from the Node app's own `schema_migrations`, so
# this application can be pointed at a database the Node app built and adopt it
# in place: every migration is idempotent SQL, and Ecto only needs somewhere of
# its own to record that it has run them.
config :rnews1, Rnews1.Repo,
  migration_source: "ecto_schema_migrations",
  types: Rnews1.PostgrexTypes

config :rnews1, Rnews1Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Rnews1Web.ErrorHTML, json: Rnews1Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Rnews1.PubSub,
  live_view: [signing_salt: "m5Hed/mB"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Only started when a Chrome is found; see Rnews1.PDF.
config :chromic_pdf, on_demand: false

import_config "#{config_env()}.exs"
