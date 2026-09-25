defmodule Rnews1.Companies do
  @moduledoc "Tenant settings, the published-feed lookup, and billing state changes."
  alias Rnews1.DB

  @active_billing_statuses ["active"]
  def active_billing_statuses, do: @active_billing_statuses
  def billing_active?(status), do: status in @active_billing_statuses

  @doc "Topics are shared across tenants: the key is a hash of language plus query."
  def save_settings(tenant_id, input, topic) do
    DB.transaction(fn ->
      DB.execute("INSERT INTO topics(key,query,language) VALUES($1,$2,$3) ON CONFLICT(key) DO NOTHING", [
        topic.key,
        topic.query,
        input.language
      ])

      DB.execute(
        """
        UPDATE tenants SET name=$1, domain=$2, industry=$3, keywords=$4, language=$5, topic_key=$6
        WHERE id=$7
        """,
        [input.name, input.domain, input.industry, input.keywords, input.language, topic.key, tenant_id]
      )

      :ok
    end)
  end

  def find_preview(nil), do: %{items: [], refreshed_at: nil}

  def find_preview(topic_key) do
    DB.one("SELECT COALESCE(items,'[]'::jsonb) AS items, refreshed_at FROM topics WHERE key=$1", [topic_key]) ||
      %{items: [], refreshed_at: nil}
  end

  @doc """
  The public feed, embed and hosted-article routes resolve through here, so a
  lapsed subscription takes the published feed down with it. The stakeholder
  count comes back with the row rather than gating the query.
  """
  def find_public_tenant(public_token) do
    DB.one(
      """
      SELECT t.*, COALESCE(p.items,'[]'::jsonb) AS items, p.refreshed_at,
             d.hostname AS custom_hostname,
             (SELECT count(*)::int FROM subscribers s WHERE s.tenant_id = t.id AND s.state <> 'unsubscribed') AS stakeholder_count
      FROM tenants t
      JOIN topics p ON p.key=t.topic_key
      LEFT JOIN tenant_domains d ON d.tenant_id = t.id AND d.verified_at IS NOT NULL
      WHERE t.public_token=$1 AND t.billing_status = ANY($2)
      """,
      [public_token, @active_billing_statuses]
    )
  end

  @doc "Serialises the PayPal dance for one tenant under its row lock."
  def with_billing_lock(tenant_id, fun) do
    DB.transaction(fn ->
      tenant = DB.one("SELECT * FROM tenants WHERE id=$1 FOR UPDATE", [tenant_id])
      fun.(tenant)
    end)
  end

  def set_subscription(tenant_id, subscription_id, status) do
    DB.execute("UPDATE tenants SET paypal_subscription_id=$1, billing_status=$2 WHERE id=$3", [
      subscription_id,
      status,
      tenant_id
    ])
  end

  def set_billing_status(tenant_id, subscription_id, status) do
    DB.execute("UPDATE tenants SET billing_status=$2 WHERE id=$1 AND paypal_subscription_id=$3", [
      tenant_id,
      status,
      subscription_id
    ])
  end

  @doc "Keyed on the subscription id, so a forged custom_id cannot move a subscription."
  def sync_subscription(%{subscription_id: subscription_id, status: status}) do
    DB.execute("UPDATE tenants SET billing_status=$2 WHERE paypal_subscription_id=$1", [subscription_id, status]) > 0
  end

  def with_owner_of_subscription(subscription_id, fun) do
    DB.transaction(fn ->
      case DB.one("SELECT * FROM tenants WHERE paypal_subscription_id=$1 FOR UPDATE", [subscription_id]) do
        nil -> nil
        tenant -> fun.(tenant)
      end
    end)
  end

  @doc "Every tenant whose feed is actually live: paying, and past the stakeholder gate."
  def list_published(limit \\ 500) do
    DB.all(
      """
      SELECT t.public_token, t.topic_key, t.name FROM tenants t
      WHERE t.billing_status = ANY($1) AND t.topic_key IS NOT NULL
        AND (SELECT count(*) FROM subscribers s WHERE s.tenant_id = t.id AND s.state <> 'unsubscribed') >= $2
      ORDER BY t.created_at LIMIT $3
      """,
      [@active_billing_statuses, Rnews1.Subscribers.required_stakeholders(), limit]
    )
  end
end
