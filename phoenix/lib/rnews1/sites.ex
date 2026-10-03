defmodule Rnews1.Sites do
  @moduledoc "Tenant sites: the brandable subdomain and the customer's own hostname."
  alias Rnews1.{Companies, DB, Subscribers}
  alias Rnews1.Util.Hosts

  @rename_interval_hours 24
  @history_days 30
  @unverified_claim_days 7
  @recheck_hours 12
  @unverify_after_days 3

  def rename_interval_hours, do: @rename_interval_hours
  def history_days, do: @history_days
  def unverified_claim_days, do: @unverified_claim_days
  def recheck_hours, do: @recheck_hours
  def unverify_after_days, do: @unverify_after_days

  @site_select """
  t.*, p.refreshed_at, d.hostname AS custom_hostname,
  (SELECT count(*)::int FROM subscribers s WHERE s.tenant_id = t.id AND s.state <> 'unsubscribed') AS stakeholder_count
  FROM tenants t
  LEFT JOIN topics p ON p.key = t.topic_key
  LEFT JOIN tenant_domains d ON d.tenant_id = t.id AND d.verified_at IS NOT NULL
  """

  @doc "Published means paying, past the roster gate, and with a topic to show."
  def published?(nil), do: false

  def published?(tenant) do
    not is_nil(tenant[:topic_key]) and Companies.billing_active?(tenant[:billing_status]) and
      (tenant[:stakeholder_count] || 0) >= Subscribers.required_stakeholders()
  end

  # ---- creating tenants -----------------------------------------------------

  @doc """
  The one place a tenant row is made. Every tenant needs a subdomain from the
  first moment, and the label may collide, so the insert tries numbered
  variants behind savepoints. Must run inside a transaction.
  """
  def ensure_tenant(%{email: email} = opts) do
    case DB.one("SELECT id FROM tenants WHERE owner_email = $1", [email]) do
      %{id: id} -> id
      nil -> insert_tenant(email, Map.get(opts, :columns, %{}))
    end
  end

  defp insert_tenant(email, columns) do
    base = Hosts.suggest_label(email: email)
    names = Map.keys(columns)
    values = Map.values(columns)
    extra_cols = Enum.map_join(names, "", &", #{&1}")
    extra_params = names |> Enum.with_index(3) |> Enum.map_join("", fn {_, i} -> ", $#{i}" end)

    Enum.reduce_while(1..25, nil, fn attempt, _ ->
      label = if attempt == 1, do: base, else: "#{base}-#{attempt}"

      if DB.one("SELECT 1 AS x FROM tenants WHERE subdomain = $1", [label]) != nil or publication_label?(label) do
        {:cont, nil}
      else
        DB.execute("SAVEPOINT tenant_insert")

        try do
          id =
            DB.value(
              "INSERT INTO tenants(owner_email, subdomain#{extra_cols}) VALUES($1, $2#{extra_params}) RETURNING id",
              [email, label | values]
            )

          DB.execute("RELEASE SAVEPOINT tenant_insert")
          {:halt, id}
        rescue
          e in Postgrex.Error ->
            DB.execute("ROLLBACK TO SAVEPOINT tenant_insert")

            case e.postgres do
              %{code: :unique_violation, constraint: "tenants_subdomain_key"} ->
                {:cont, nil}

              %{code: :unique_violation} ->
                case DB.one("SELECT id FROM tenants WHERE owner_email = $1", [email]) do
                  %{id: id} -> {:halt, id}
                  nil -> reraise e, __STACKTRACE__
                end

              _ ->
                reraise e, __STACKTRACE__
            end
        end
      end
    end) ||
      DB.value("INSERT INTO tenants(owner_email, subdomain) VALUES($1, $2) RETURNING id", [email, Hosts.placeholder_label()])
  end

  # ---- resolving a host to a tenant ----------------------------------------

  def find_by_subdomain(label), do: DB.one("SELECT #{@site_select} WHERE t.subdomain = $1", [label])
  def find_by_custom_hostname(hostname), do: DB.one("SELECT #{@site_select} WHERE d.hostname = $1", [hostname])
  def find_site_by_id(tenant_id), do: DB.one("SELECT #{@site_select} WHERE t.id = $1", [tenant_id])

  def find_by_old_subdomain(label) do
    DB.one(
      "SELECT #{@site_select} JOIN subdomain_history h ON h.tenant_id = t.id WHERE h.subdomain = $1 AND h.released_at > now() - ($2 || ' days')::interval",
      [label, to_string(@history_days)]
    )
  end

  def servable_host?(%{kind: :subdomain, label: label}) do
    DB.one(
      """
      SELECT 1 AS x FROM tenants WHERE subdomain = $1
      UNION ALL SELECT 1 FROM subdomain_history WHERE subdomain = $1 AND released_at > now() - ($2 || ' days')::interval LIMIT 1
      """,
      [label, to_string(@history_days)]
    ) != nil
  end

  def servable_host?(%{kind: :custom, host: host}) do
    DB.one("SELECT 1 AS x FROM tenant_domains WHERE hostname = $1 AND verified_at IS NOT NULL", [host]) != nil
  end

  def servable_host?(_), do: false

  def verified_hostnames, do: DB.all("SELECT hostname FROM tenant_domains WHERE verified_at IS NOT NULL") |> Enum.map(& &1.hostname)

  # ---- renaming -----------------------------------------------------------------

  def next_rename_at(%{subdomain_changed_at: %DateTime{} = changed}) do
    at = DateTime.add(changed, @rename_interval_hours * 3600, :second)
    if DateTime.compare(at, DateTime.utc_now()) == :gt, do: at, else: nil
  end

  def next_rename_at(_), do: nil

  @doc """
  Renames inside the row lock: {:ok, label} | {:error, :invalid | :same | :taken | {:throttled, next_at}}
  """
  def rename(tenant_id, label) do
    if not Hosts.valid_label?(label) do
      {:error, :invalid}
    else
      DB.transaction(fn ->
        current = DB.one("SELECT subdomain, subdomain_changed_at FROM tenants WHERE id = $1 FOR UPDATE", [tenant_id])

        cond do
          is_nil(current) -> {:error, :invalid}
          current.subdomain == label -> {:error, :same}
          next = next_rename_at(current) -> {:error, {:throttled, next}}
          not label_free?(label, tenant_id) -> {:error, :taken}
          true -> move_label(tenant_id, current.subdomain, label, true)
        end
      end)
    end
  end

  defp move_label(tenant_id, from, to, count_as_rename) do
    DB.execute(
      """
      INSERT INTO subdomain_history(subdomain, tenant_id, released_at) VALUES($1, $2, now())
      ON CONFLICT (subdomain) DO UPDATE SET tenant_id = EXCLUDED.tenant_id, released_at = now()
      """,
      [from, tenant_id]
    )

    DB.execute("DELETE FROM subdomain_history WHERE subdomain = $1 AND tenant_id = $2", [to, tenant_id])

    sql =
      if count_as_rename,
        do: "UPDATE tenants SET subdomain = $2, subdomain_changed_at = now() WHERE id = $1",
        else: "UPDATE tenants SET subdomain = $2 WHERE id = $1"

    DB.execute(sql, [tenant_id, to])
    {:ok, to}
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] == :unique_violation, do: {:error, :taken}, else: reraise(e, __STACKTRACE__)
  end

  # Free means: no tenant has it now, nobody else released it recently, and no
  # publication of ours is served on it.
  defp label_free?(label, tenant_id) do
    not publication_label?(label) and
      DB.one(
        """
        SELECT 1 AS x FROM tenants WHERE subdomain = $1
        UNION ALL SELECT 1 FROM subdomain_history WHERE subdomain = $1 AND tenant_id <> $2 AND released_at > now() - ($3 || ' days')::interval
        LIMIT 1
        """,
        [label, tenant_id, to_string(@history_days)]
      ) == nil
  end

  @doc """
  Whether one of our own news sites is served on this platform label.

  The host plug resolves publications before tenants, so a tenant allowed to
  take a label a publication already holds would be shadowed by a site it does
  not own — its readers would silently get the publication instead. Both the
  rename path and the first label a new tenant is given have to refuse it.
  """
  def publication_label?(label) do
    DB.one("SELECT 1 AS x FROM publications WHERE hostname = $1", [Hosts.platform_host(label)]) != nil
  end

  @doc """
  Moves a tenant off a label onto a free one, returning the new label.

  For a tenant parked on a host that is not its own. It does not count as a
  rename: the owner did not ask for it, so it must not burn their once-a-day
  allowance or leave them unable to choose a better name straight afterwards.
  """
  def release_label(tenant_id, from, email) do
    base = Hosts.suggest_label(name: "", email: email)

    label =
      Enum.find_value(1..25, fn n ->
        candidate = if n == 1, do: base, else: "#{base}-#{n}"
        if label_free?(candidate, tenant_id), do: candidate
      end)

    if label do
      DB.transaction(fn -> move_label(tenant_id, from, label, false) end)
      label
    end
  end

  @doc """
  Whether a tenant answers on this platform label, now or still by redirect.

  The mirror of publication_label?/1, for the other direction: a publication
  must not be created on a label a customer holds, nor on one released inside
  the redirect window, because the host plug would resolve the publication
  first and their site would stop existing.
  """
  def label_held?(label) do
    DB.one(
      """
      SELECT 1 AS x FROM tenants WHERE subdomain = $1
      UNION ALL SELECT 1 FROM subdomain_history WHERE subdomain = $1 AND released_at > now() - ($2 || ' days')::interval
      LIMIT 1
      """,
      [label, to_string(@history_days)]
    ) != nil
  end

  @doc "Swaps a placeholder for a label made from the company name. Not a rename in the owner's budget."
  def adopt_name_label(tenant_id, name) do
    tenant = find_site_by_id(tenant_id)

    cond do
      is_nil(tenant) or not Hosts.placeholder_label?(tenant.subdomain) ->
        tenant && tenant.subdomain

      true ->
        base = Hosts.suggest_label(name: name)

        if Hosts.placeholder_label?(base) do
          tenant.subdomain
        else
          Enum.find_value(1..10, tenant.subdomain, fn attempt ->
            label = if attempt == 1, do: base, else: "#{base}-#{attempt}"

            DB.transaction(fn ->
              if label_free?(label, tenant_id) do
                case DB.execute("UPDATE tenants SET subdomain = $2 WHERE id = $1", [tenant_id, label]) do
                  _ -> label
                end
              end
            end)
          end)
        end
    end
  end

  # ---- custom domains -----------------------------------------------------------

  def custom_domain_for(tenant_id), do: DB.one("SELECT * FROM tenant_domains WHERE tenant_id = $1", [tenant_id])

  @doc "{:ok, domain} | {:error, :taken}. A verified claim by another tenant is theirs; an unverified one gives way."
  def claim_custom_domain(tenant_id, hostname) do
    DB.transaction(fn ->
      holder = DB.one("SELECT * FROM tenant_domains WHERE hostname = $1 FOR UPDATE", [hostname])

      cond do
        holder && holder.tenant_id != tenant_id && holder.verified_at ->
          {:error, :taken}

        holder && holder.tenant_id == tenant_id ->
          {:ok, holder}

        true ->
          if holder, do: DB.execute("DELETE FROM tenant_domains WHERE id = $1", [holder.id])
          DB.execute("DELETE FROM tenant_domains WHERE tenant_id = $1", [tenant_id])

          token = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

          {:ok,
           DB.one("INSERT INTO tenant_domains(tenant_id, hostname, verification_token) VALUES($1, $2, $3) RETURNING *", [
             tenant_id,
             hostname,
             token
           ])}
      end
    end)
  end

  def remove_custom_domain(tenant_id), do: DB.execute("DELETE FROM tenant_domains WHERE tenant_id = $1", [tenant_id]) > 0

  def record_check(id, %{ok: true}) do
    DB.one(
      """
      UPDATE tenant_domains SET verified_at = COALESCE(verified_at, now()), last_checked_at = now(), last_error = NULL, failing_since = NULL
      WHERE id = $1 RETURNING *
      """,
      [id]
    )
  end

  def record_check(id, %{ok: false} = check) do
    DB.one(
      """
      UPDATE tenant_domains
      SET last_checked_at = now(), last_error = $2, failing_since = COALESCE(failing_since, now()),
          verified_at = CASE WHEN verified_at IS NOT NULL AND COALESCE(failing_since, now()) < now() - ($3 || ' days')::interval
                        THEN NULL ELSE verified_at END
      WHERE id = $1 RETURNING *
      """,
      [id, String.slice(to_string(Map.get(check, :error) || "check failed"), 0, 300), to_string(@unverify_after_days)]
    )
  end

  def domains_due_for_check(limit \\ 50) do
    DB.all(
      """
      SELECT d.*, t.subdomain FROM tenant_domains d JOIN tenants t ON t.id = d.tenant_id
      WHERE d.verified_at IS NOT NULL AND (d.last_checked_at IS NULL OR d.last_checked_at < now() - ($2 || ' hours')::interval)
      ORDER BY d.last_checked_at NULLS FIRST LIMIT $1
      """,
      [limit, to_string(@recheck_hours)]
    )
  end

  def expire_unverified_claims do
    DB.execute("DELETE FROM tenant_domains WHERE verified_at IS NULL AND created_at < now() - ($1 || ' days')::interval", [
      to_string(@unverified_claim_days)
    ])
  end
end
