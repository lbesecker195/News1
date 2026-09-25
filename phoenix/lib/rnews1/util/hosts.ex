defmodule Rnews1.Util.Hosts do
  @moduledoc """
  Hostnames: which of ours a request is for, what a tenant may call their
  subdomain, and what a customer may point at us.

  Three kinds of host reach the app:

    app        the APP_ORIGIN host — marketing, dashboard, API, admin
    archive    the ARCHIVE_ORIGIN host, www by default — the editorial archive
    subdomain  {label}.SITES_DOMAIN — one tenant's public site
    custom     anything else — a customer's own hostname, served once verified
  """
  alias Rnews1.Env

  @reserved MapSet.new(~w(
    www app admin api mail mg email smtp imap pop ftp ns1 ns2 cdn static assets
    status help support docs blog dev staging test login register billing paypal
    webhooks feed feeds embed news brief pdf rnews1 localhost
    gmail googlemail yahoo outlook hotmail live icloud me aol proton protonmail
    pm gmx yandex zoho
  ))

  @label ~r/^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$/
  @min_label 3
  @max_label 63

  def reserved, do: @reserved
  def reserved?(label), do: MapSet.member?(@reserved, label)

  @doc "nil when the label is fine, otherwise the reason it is not."
  def label_error(label) do
    value = to_string(label || "")

    cond do
      not Regex.match?(@label, value) ->
        "Use #{@min_label}–#{@max_label} lowercase letters, digits and hyphens, starting and ending with a letter or digit."

      String.starts_with?(value, "xn--") ->
        "That prefix is reserved for internationalised names."

      reserved?(value) ->
        "That name is reserved."

      true ->
        nil
    end
  end

  def valid_label?(label), do: label_error(label) == nil

  @doc "The label a tenant gets before anyone has chosen one."
  def placeholder_label?(label), do: Regex.match?(~r/^news-[0-9a-f]{8}$/, to_string(label))

  def placeholder_label do
    "news-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end

  @doc """
  A starting point for a new tenant: the company name when there is one, else
  the organisation part of their email (jane@acme.com → acme). Freemail and
  anything too short or reserved get a placeholder.
  """
  def suggest_label(opts \\ []) do
    name = Keyword.get(opts, :name, "") || ""
    email = Keyword.get(opts, :email, "") || ""

    from_name = Rnews1.Util.Slug.label(name)

    cond do
      String.length(from_name) >= @min_label and not reserved?(from_name) ->
        from_name

      true ->
        domain = email |> String.split("@") |> Enum.at(1) || ""
        from_email = domain |> String.split(".") |> List.first() |> Rnews1.Util.Slug.label()

        if String.length(from_email) >= @min_label and not reserved?(from_email),
          do: from_email,
          else: placeholder_label()
    end
  end

  # ---- which host is this ------------------------------------------------

  @ipv4 ~r/^\d{1,3}(\.\d{1,3}){3}$/

  defp loopback_or_ip?(host), do: host == "localhost" or Regex.match?(@ipv4, host) or String.contains?(host, ":")

  def classify(host, opts \\ []) do
    app_host = Keyword.get(opts, :app_host) || Env.app_host()
    archive_host = Keyword.get(opts, :archive_host) || Env.archive_host()
    sites_domain = Keyword.get(opts, :sites_domain) || Env.sites_domain()

    value = host |> to_string() |> String.downcase() |> String.trim_trailing(".")

    cond do
      value == "" or value == app_host or loopback_or_ip?(value) ->
        %{kind: :app}

      value == archive_host ->
        %{kind: :archive, host: value}

      value == sites_domain ->
        %{kind: :app}

      String.ends_with?(value, "." <> sites_domain) ->
        label = String.slice(value, 0, String.length(value) - String.length(sites_domain) - 1)

        if String.contains?(label, ".") or not Regex.match?(@label, label) do
          %{kind: :none, host: value}
        else
          # A reserved label — app, mail, api — that no tenant can hold falls
          # back to the app rather than 404ing; it is still looked up first so
          # the fallback never shadows a real site.
          %{kind: :subdomain, label: label, host: value, reserved: reserved?(label)}
        end

      true ->
        %{kind: :custom, host: value}
    end
  end

  # ---- building site URLs ------------------------------------------------

  def platform_host(subdomain), do: "#{subdomain}.#{Env.sites_domain()}"

  @doc """
  The archive's own label — "www" for www.rnews1.com — when the archive is a
  subdomain of the platform domain, which is the subdomain the house account
  holds.
  """
  def archive_label do
    host = Env.archive_host()
    suffix = "." <> Env.sites_domain()

    if String.ends_with?(host, suffix) do
      label = String.slice(host, 0, String.length(host) - String.length(suffix))
      if String.contains?(label, "."), do: nil, else: label
    end
  end

  @doc """
  A tenant's canonical origin: their verified custom domain when they have
  one, otherwise their platform subdomain. Scheme and port follow APP_ORIGIN.
  """
  def site_origin(tenant) do
    uri = Env.app_uri()
    port = if uri.port in [nil, 80, 443], do: "", else: ":#{uri.port}"
    host = Map.get(tenant, :custom_hostname) || platform_host(Map.get(tenant, :subdomain))
    "#{uri.scheme}://#{host}#{port}"
  end

  # ---- customer hostnames ------------------------------------------------

  @hostname ~r/^(?=.{4,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/

  @doc "Lowercase, no scheme, no path, no trailing dot. nil if unusable."
  def normalise_hostname(input) do
    value = input |> to_string() |> String.trim() |> String.downcase()

    value =
      if Regex.match?(~r/^[a-z][a-z0-9+.-]*:\/\//, value) do
        case URI.parse(value) do
          %URI{host: host} when is_binary(host) -> host
          _ -> ""
        end
      else
        value
      end

    value =
      value
      |> String.split("/")
      |> List.first()
      |> String.split("?")
      |> List.first()
      |> String.split(":")
      |> List.first()
      |> String.trim_trailing(".")

    if Regex.match?(@hostname, value), do: value, else: nil
  end

  @doc "Why a hostname cannot be a custom domain, or nil."
  def hostname_error(hostname, opts \\ []) do
    app_host = Keyword.get(opts, :app_host) || Env.app_host()
    archive_host = Keyword.get(opts, :archive_host) || Env.archive_host()
    sites_domain = Keyword.get(opts, :sites_domain) || Env.sites_domain()

    cond do
      is_nil(hostname) or hostname == "" ->
        "Enter a hostname like news.yourcompany.com."

      loopback_or_ip?(hostname) ->
        "Use a domain name, not an IP address."

      hostname in [app_host, archive_host, sites_domain] ->
        "That hostname belongs to the platform."

      String.ends_with?(hostname, "." <> sites_domain) ->
        "Addresses under #{sites_domain} are platform subdomains — change yours in the Subdomain field instead."

      true ->
        nil
    end
  end

  @doc "Accepts what people type — https://www.Example.com/about — and returns the bare host."
  @domain ~r/^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/

  def company_domain(input) do
    value = input |> to_string() |> String.trim() |> String.downcase()

    if value == "" do
      {:error, "A company domain is required."}
    else
      value =
        case String.split(value, "@") do
          [_ | _] = parts when length(parts) > 1 -> List.last(parts)
          _ -> value
        end

      value =
        if Regex.match?(~r/^[a-z][a-z0-9+.-]*:\/\//, value) do
          URI.parse(value).host || ""
        else
          value
        end

      value =
        value
        |> String.split("/") |> List.first()
        |> String.split("?") |> List.first()
        |> String.split("#") |> List.first()
        |> String.split(":") |> List.first()
        |> String.replace(~r/^www\./, "")
        |> String.trim_trailing(".")

      if Regex.match?(@domain, value), do: {:ok, value}, else: {:error, "Invalid company domain."}
    end
  end
end
