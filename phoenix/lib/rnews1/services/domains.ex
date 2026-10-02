defmodule Rnews1.Domains do
  @moduledoc """
  Proving a customer controls the hostname they want served: a CNAME to the
  claiming tenant's OWN subdomain, or a TXT record carrying the token. The
  resolver is injectable so the checks can be tested without DNS.
  """
  alias Rnews1.Sites
  alias Rnews1.Util.Hosts

  @txt_label "_rnews1"
  @txt_prefix "rnews1-verify="
  @no_record [:nxdomain, :nodata, :servfail, :enotfound, :enodata]

  def txt_name(hostname), do: "#{@txt_label}.#{hostname}"
  def txt_value(domain), do: @txt_prefix <> domain.verification_token

  def dns_records(domain, tenant) do
    [
      %{type: "CNAME", name: domain.hostname, value: Hosts.platform_host(tenant.subdomain), purpose: "Routes traffic to your site and verifies the domain."},
      %{type: "TXT", name: txt_name(domain.hostname), value: txt_value(domain), purpose: "Only needed if your provider hides the CNAME (proxied or flattened records)."}
    ]
  end

  @doc "The default resolver: %{cname: fun, txt: fun}, each returning {:ok, records} | {:error, reason}."
  def system_resolver do
    %{
      cname: fn host -> resolve(host, :cname) |> map_ok(fn data -> Enum.map(data, &to_string/1) end) end,
      txt: fn host -> resolve(host, :txt) |> map_ok(fn data -> Enum.map(data, fn chunks -> chunks |> List.wrap() |> Enum.map_join("", &to_string/1) end) end) end
    }
  end

  defp resolve(host, type) do
    case :inet_res.resolve(String.to_charlist(host), :in, type, [], 5_000) do
      {:ok, msg} ->
        records =
          msg
          |> :inet_dns.msg(:anlist)
          |> Enum.filter(&(:inet_dns.rr(&1, :type) == type))
          |> Enum.map(&:inet_dns.rr(&1, :data))

        if records == [], do: {:error, :nodata}, else: {:ok, records}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :formerr}
  end

  defp map_ok({:ok, data}, fun), do: {:ok, fun.(data)}
  defp map_ok(other, _), do: other

  def check_domain(domain, tenant, resolver \\ system_resolver()) do
    target = Hosts.platform_host(tenant.subdomain)
    cname = safe(resolver.cname, domain.hostname)

    cond do
      match?({:ok, _}, cname) and Enum.any?(elem(cname, 1), &(clean(&1) == target)) ->
        %{ok: true, method: "cname"}

      true ->
        txt = safe(resolver.txt, txt_name(domain.hostname))
        wanted = txt_value(domain)

        if match?({:ok, _}, txt) and Enum.any?(elem(txt, 1), &(&1 == wanted)) do
          %{ok: true, method: "txt"}
        else
          %{ok: false, method: nil, reason: describe(cname, txt, target, domain.hostname)}
        end
    end
  end

  defp safe(fun, host) do
    fun.(host)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp describe(cname, txt, target, hostname) do
    case {cname, txt} do
      {{:ok, [first | _]}, _} ->
        "#{hostname} is a CNAME to #{clean(first)}, not to #{target}."

      {{:error, reason}, _} when reason not in @no_record ->
        "DNS lookup failed (#{format_reason(reason)}). Try again in a few minutes."

      {_, {:ok, [_ | _]}} ->
        "Found a TXT record at #{txt_name(hostname)} but not the verification value."

      _ ->
        "No CNAME to #{target} and no verification TXT record found yet. DNS changes can take up to an hour to be visible."
    end
  end

  defp format_reason(reason) when is_atom(reason), do: reason |> to_string() |> String.upcase()
  defp format_reason(reason), do: to_string(reason)

  defp clean(value), do: value |> to_string() |> String.downcase() |> String.trim_trailing(".")

  def verify_now(tenant_id, resolver \\ system_resolver()) do
    case Sites.custom_domain_for(tenant_id) do
      nil ->
        nil

      domain ->
        tenant = Sites.find_site_by_id(tenant_id)
        check = check_domain(domain, tenant, resolver)
        updated = Sites.record_check(domain.id, %{ok: check.ok, error: check[:reason]})
        %{domain: updated, check: check}
    end
  end

  def recheck_domains(opts \\ []) do
    resolver = Keyword.get(opts, :resolver, system_resolver())
    due = Sites.domains_due_for_check(Keyword.get(opts, :limit, 50))

    {verified, failing} =
      Enum.reduce(due, {0, 0}, fn domain, {v, f} ->
        check = check_domain(domain, %{subdomain: domain.subdomain}, resolver)
        Sites.record_check(domain.id, %{ok: check.ok, error: check[:reason]})
        if check.ok, do: {v + 1, f}, else: {v, f + 1}
      end)

    %{checked: length(due), verified: verified, failing: failing, dropped: Sites.expire_unverified_claims()}
  end
end

defmodule Rnews1.House do
  @moduledoc """
  The platform's own account: the archive at www is an enterprise tenant,
  comped, holding the archive's own subdomain. Made true on every boot.
  """
  alias Rnews1.{DB, Env, Publications, Sites}
  alias Rnews1.Util.Hosts

  @reason "platform demo account — the archive at ARCHIVE_ORIGIN is this tenant's site"

  def ensure_house_account(email \\ Env.archive_tenant_email()) do
    if is_nil(email) or email == "" do
      nil
    else
      label = Hosts.archive_label()
      tenant_id = DB.transaction(fn -> Sites.ensure_tenant(%{email: email}) end)

      result =
        DB.one(
          """
          UPDATE tenants
          SET plan = 'enterprise', billing_status = 'active', comped_reason = COALESCE(comped_reason, $3),
              subdomain = CASE
                WHEN $2::text IS NULL THEN subdomain
                WHEN NOT EXISTS (SELECT 1 FROM tenants other WHERE other.subdomain = $2 AND other.id <> tenants.id) THEN $2
                ELSE subdomain END
          WHERE id = $1
          RETURNING owner_email, subdomain, plan, comped_reason
          """,
          [tenant_id, label, @reason]
        )

      # The archive belongs to the house account. Adopted here rather than in
      # Publications.ensure_default/0 because that runs first at boot, when this
      # tenant may not exist yet — or ever, if ARCHIVE_TENANT_EMAIL is unset.
      # `tenant_id IS NULL` keeps it idempotent and stops it taking a row that
      # has deliberately been pointed somewhere else.
      Publications.adopt(Publications.default_slug(), tenant_id)

      result
    end
  end
end
