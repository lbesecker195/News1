defmodule Rnews1.Env do
  @moduledoc """
  Runtime configuration, read from the application environment that
  config/runtime.exs fills from the same variable names the Node app used.

  Derived values live here rather than in config so that they are computed
  from whatever the raw values are at the time — tests override a few and
  expect the derivations to follow.
  """

  def all, do: Application.get_env(:rnews1, :env, [])

  def get(key, default \\ nil) do
    case Keyword.get(all(), key) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  def app_origin, do: get(:app_origin, "http://localhost:4000")

  def app_uri, do: URI.parse(app_origin())

  def app_host, do: app_uri().host

  @doc """
  Where customer sites live: `{subdomain}.SITES_DOMAIN`. Defaults to the app
  host without a leading www. or app., so https://app.rnews1.com puts
  customers at acme.rnews1.com. In development it is localhost, which
  browsers resolve as `*.localhost` on their own.
  """
  def sites_domain do
    case get(:sites_domain) do
      nil -> app_host() |> String.replace(~r/^(www|app)\./, "") |> String.downcase()
      value -> value |> String.downcase() |> String.trim_trailing(".")
    end
  end

  @doc "The editorial archive's origin: www.SITES_DOMAIN unless set."
  def archive_origin do
    case get(:archive_origin) do
      nil ->
        uri = app_uri()
        port = if uri.port in [nil, 80, 443], do: "", else: ":#{uri.port}"
        "#{uri.scheme}://www.#{sites_domain()}#{port}"

      value ->
        value |> URI.parse() |> then(&"#{&1.scheme}://#{&1.host}#{port_suffix(&1)}")
    end
  end

  defp port_suffix(%URI{port: port, scheme: scheme}) do
    default = if scheme == "https", do: 443, else: 80
    if port in [nil, default], do: "", else: ":#{port}"
  end

  def archive_host, do: URI.parse(archive_origin()).host

  @doc "SeriouslySimpleAnalytics account (acct_…); nil switches the tracker off."
  def ssa_account_id, do: get(:ssa_account_id)

  def archive_tenant_email, do: get(:archive_tenant_email) |> downcase()

  def own_hosts do
    get(:own_hosts, "")
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  def support_email, do: get(:support_email, "support@example.com")
  def business_address, do: get(:business_address, "")
  def data_dir, do: get(:data_dir, Path.expand("data"))
  def pdf_dir, do: Path.join(data_dir(), "pdfs")

  def paypal_mode, do: get(:paypal_mode, "sandbox")

  def paypal_base_url do
    get(:paypal_base_url) ||
      if paypal_mode() == "live",
        do: "https://api-m.paypal.com",
        else: "https://api-m.sandbox.paypal.com"
  end

  def paypal_client_id, do: get(:paypal_client_id, "")
  def paypal_client_secret, do: get(:paypal_client_secret, "")
  def paypal_webhook_id, do: get(:paypal_webhook_id, "")
  def paypal_configured?, do: paypal_client_id() != "" and paypal_client_secret() != ""

  def mailgun_api_key, do: get(:mailgun_api_key, "")
  def mailgun_domain, do: get(:mailgun_domain, "")
  def mailgun_from, do: get(:mailgun_from, "")
  def mailgun_signing_key, do: get(:mailgun_signing_key, "")
  def mailgun_api_base, do: get(:mailgun_api_base, "https://api.mailgun.net")

  def treg_token, do: get(:treg_token, "")
  def treg_base_url, do: get(:treg_base_url, "https://treg.to")
  def news_provider, do: get(:news_provider, "exa")

  def openai_api_key, do: get(:openai_api_key, "")
  def openai_model, do: get(:openai_model, "gpt-5.6-luna")

  def digest_hour, do: get(:digest_hour, 13)

  def chrome_no_sandbox?, do: get(:chrome_no_sandbox, false) == true
  def chrome_executable, do: get(:chrome_executable)

  def https?, do: String.starts_with?(app_origin(), "https://")

  @doc "Raises naming every missing variable, so a bad deploy fails at boot."
  def require!(keys) do
    names = %{
      openai_api_key: "OPENAI_API_KEY",
      treg_token: "TREG_TOKEN",
      mailgun_api_key: "MAILGUN_API_KEY",
      mailgun_domain: "MAILGUN_DOMAIN",
      mailgun_from: "MAILGUN_FROM",
      mailgun_signing_key: "MAILGUN_WEBHOOK_SIGNING_KEY",
      business_address: "BUSINESS_ADDRESS",
      support_email: "SUPPORT_EMAIL"
    }

    missing = Enum.filter(keys, &(get(&1) in [nil, ""]))

    if missing != [] do
      raise "Missing required environment variables: " <>
              Enum.map_join(missing, ", ", &Map.get(names, &1, to_string(&1)))
    end

    :ok
  end

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)
end
