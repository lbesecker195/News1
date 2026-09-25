import Config

# The same variable names as the Node application, so one /etc/rnews1/env (or
# one saas/.env) serves both during the cutover.
#
# In development the project's own .env is read when present, the way
# `node --env-file=.env` did: values are taken as the rest of the line, unquoted,
# because BUSINESS_ADDRESS has spaces and commas in it.
env = config_env()

dotenv =
  case File.read(Path.expand("../.env", __DIR__)) do
    {:ok, text} when env != :test ->
      text
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))
      |> Enum.flat_map(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> [{String.trim(key), String.trim(value)}]
          _ -> []
        end
      end)
      |> Map.new()

    _ ->
      %{}
  end

read = fn name, default ->
  case System.get_env(name) || Map.get(dotenv, name) do
    nil -> default
    "" -> default
    value -> String.trim(value)
  end
end

integer = fn name, default ->
  case read.(name, nil) do
    nil -> default
    value -> String.to_integer(value)
  end
end

if env != :test do
  config :rnews1, :env,
    app_origin: read.("APP_ORIGIN", "http://localhost:4000"),
    sites_domain: read.("SITES_DOMAIN", nil),
    archive_origin: read.("ARCHIVE_ORIGIN", nil),
    archive_tenant_email: read.("ARCHIVE_TENANT_EMAIL", nil),
    own_hosts: read.("OWN_HOSTS", ""),
    support_email: read.("SUPPORT_EMAIL", "support@example.com"),
    business_address: read.("BUSINESS_ADDRESS", ""),
    data_dir: Path.expand(read.("DATA_DIR", "./data"), Path.expand("..", __DIR__)),
    trust_proxy: read.("TRUST_PROXY", "") == "1",
    paypal_mode: read.("PAYPAL_MODE", "sandbox"),
    paypal_base_url: read.("PAYPAL_BASE_URL", nil),
    paypal_client_id: read.("PAYPAL_CLIENT_ID", ""),
    paypal_client_secret: read.("PAYPAL_CLIENT_SECRET", ""),
    paypal_webhook_id: read.("PAYPAL_WEBHOOK_ID", ""),
    mailgun_api_key: read.("MAILGUN_API_KEY", ""),
    mailgun_domain: read.("MAILGUN_DOMAIN", ""),
    mailgun_from: read.("MAILGUN_FROM", ""),
    mailgun_signing_key: read.("MAILGUN_WEBHOOK_SIGNING_KEY", ""),
    mailgun_api_base: String.trim_trailing(read.("MAILGUN_API_BASE", "https://api.mailgun.net"), "/"),
    treg_token: read.("TREG_TOKEN", ""),
    treg_base_url: String.trim_trailing(read.("TREG_BASE_URL", "https://treg.to"), "/"),
    news_provider: read.("NEWS_PROVIDER", "exa"),
    openai_api_key: read.("OPENAI_API_KEY", ""),
    openai_model: read.("OPENAI_MODEL", "gpt-5.6-luna"),
    ssa_account_id: read.("SSA_ACCOUNT_ID", nil),
    digest_hour: integer.("DIGEST_HOUR", 13),
    chrome_no_sandbox: read.("PUPPETEER_NO_SANDBOX", "") == "1" or read.("CHROME_NO_SANDBOX", "") == "1",
    chrome_executable: read.("CHROME_EXECUTABLE", nil)

  # The web app and the worker are one release; WORKER=0 runs a web-only node.
  config :rnews1, start_workers: read.("WORKER", "1") != "0"

  # Bind to the loopback behind Caddy; BIND_HOST=0.0.0.0 to expose directly.
  bind =
    case read.("BIND_HOST", if(config_env() == :prod, do: "127.0.0.1", else: "127.0.0.1")) do
      "0.0.0.0" -> {0, 0, 0, 0}
      _ -> {127, 0, 0, 1}
    end

  app_uri = URI.parse(read.("APP_ORIGIN", "http://localhost:4000"))

  config :rnews1, Rnews1Web.Endpoint,
    http: [ip: bind, port: integer.("PORT", 4000)],
    url: [host: app_uri.host, port: app_uri.port, scheme: app_uri.scheme]
end

if System.get_env("PHX_SERVER") do
  config :rnews1, Rnews1Web.Endpoint, server: true
end

if config_env() == :prod do
  config :rnews1, Rnews1.Repo,
    url: read.("DATABASE_URL", nil) || raise("DATABASE_URL is missing"),
    pool_size: integer.("POOL_SIZE", 10)

  config :rnews1, Rnews1Web.Endpoint,
    secret_key_base:
      read.("SECRET_KEY_BASE", nil) ||
        raise("SECRET_KEY_BASE is missing; generate one with: mix phx.gen.secret"),
    server: true
end
