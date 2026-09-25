defmodule Rnews1.Digests do
  @moduledoc "Which tenant is due today's digest, claimed under its row lock."
  alias Rnews1.{Companies, DB}

  def with_tenant_due_for_digest(date, fun) do
    DB.transaction(fn ->
      tenant =
        DB.one(
          """
          SELECT t.id, t.name, t.language, t.public_token, t.topic_key, p.query AS topic_query,
                 COALESCE(p.items,'[]'::jsonb) AS items
          FROM tenants t JOIN topics p ON p.key = t.topic_key
          WHERE t.billing_status = ANY($1) AND (t.digest_sent_on IS NULL OR t.digest_sent_on < $2::date)
            AND EXISTS (SELECT 1 FROM subscribers s WHERE s.tenant_id = t.id AND s.state = 'active')
          ORDER BY t.digest_sent_on NULLS FIRST, t.created_at LIMIT 1 FOR UPDATE OF t SKIP LOCKED
          """,
          [Companies.active_billing_statuses(), DB.date(date)]
        )

      case tenant do
        nil ->
          nil

        tenant ->
          recipients =
            DB.all(
              """
              SELECT c.id AS contact_id, c.email, c.unsub_token, c.name, c.title, c.company, c.industry
              FROM subscribers s JOIN contacts c ON c.id = s.contact_id
              WHERE s.tenant_id = $1 AND s.state = 'active' AND c.opted_out_at IS NULL AND c.bounced_at IS NULL
              ORDER BY c.email
              """,
              [tenant.id]
            )

          result = fun.(Map.put(tenant, :recipients, recipients))
          DB.execute("UPDATE tenants SET digest_sent_on=$2::date WHERE id=$1", [tenant.id, DB.date(date)])
          result
      end
    end)
  end

  def list_campaign_contacts(limit \\ 500) do
    DB.all(
      "SELECT id, email, name, company, unsub_token FROM contacts WHERE opted_out_at IS NULL AND bounced_at IS NULL ORDER BY created_at LIMIT $1",
      [limit]
    )
  end
end
