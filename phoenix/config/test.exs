import Config

config :rnews1, Rnews1.Repo,
  url: System.get_env("TEST_DATABASE_URL", "postgres://localhost:5432/rnews1_phx_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :rnews1, Rnews1Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "snkV7A23U+ZyTAF4WttFru58GGZSiC6oKqdpJC33h7nIkmuVObWa3k94XAVpAWni",
  server: false

# The environment the Node test suite ran under, so behaviour is comparable.
config :rnews1, :env,
  app_origin: "https://rnews1.test",
  support_email: "support@rnews1.test",
  business_address: "1 Test St, Springfield, CA 90000",
  data_dir: Path.expand("../tmp/test-data", __DIR__),
  paypal_mode: "sandbox",
  paypal_client_id: "client-placeholder",
  paypal_client_secret: "secret-placeholder",
  paypal_webhook_id: "WH-PLACEHOLDER",
  mailgun_api_key: "key-test",
  mailgun_domain: "mg.rnews1.test",
  mailgun_from: "RNews1 <briefings@mg.rnews1.test>",
  mailgun_signing_key: "signing-key",
  treg_token: "treg-test-token",
  openai_api_key: "sk-test",
  news_provider: "exa",
  digest_hour: 13

# Fast hashing in tests; the parameters are not what is under test.
config :argon2_elixir, t_cost: 1, m_cost: 8

# Workers never start under test; their functions are called directly.
config :rnews1, start_workers: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true
config :phoenix, sort_verified_routes_query_params: true
