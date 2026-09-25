defmodule Rnews1.PayPalEvents do
  alias Rnews1.DB

  @doc "True the first time an event id is seen; false for every retry."
  def record(%{id: id, kind: kind, resource_id: resource_id}) do
    DB.execute("INSERT INTO paypal_events(id, kind, resource_id) VALUES($1,$2,$3) ON CONFLICT(id) DO NOTHING", [
      id,
      kind,
      resource_id
    ]) > 0
  end

  def prune(days \\ 90) do
    DB.execute("DELETE FROM paypal_events WHERE received_at < now() - ($1 || ' days')::interval", [to_string(days)])
  end
end

defmodule Rnews1.PayPalPlans do
  alias Rnews1.DB

  def find_by_key(key), do: DB.one("SELECT * FROM paypal_plans WHERE key=$1", [key])

  def create(%{key: key, product_id: product_id, plan_id: plan_id, amount_cents: cents} = a) do
    DB.one(
      """
      INSERT INTO paypal_plans(key, product_id, plan_id, amount_cents, raw) VALUES($1,$2,$3,$4,$5)
      ON CONFLICT(key) DO UPDATE SET key=EXCLUDED.key RETURNING *
      """,
      [key, product_id, plan_id, cents, Map.get(a, :raw, %{})]
    )
  end
end

defmodule Rnews1.MailgunEvents do
  @moduledoc "Mailgun retries webhooks; the event id is the idempotency key."
  alias Rnews1.DB

  def record_and_apply(%{id: id, kind: kind, job_id: job_id, email: email}) do
    DB.transaction(fn ->
      inserted =
        DB.execute("INSERT INTO mailgun_events(id,kind,job_id) VALUES($1,$2,$3) ON CONFLICT(id) DO NOTHING", [
          id,
          kind,
          job_id
        ])

      if inserted == 0 do
        false
      else
        if job_id && kind in ["accepted", "delivered"] do
          DB.execute("UPDATE outbox SET status='accepted' WHERE id=$1 AND status IN ('processing','unknown','pending')", [job_id])
        end

        if job_id && kind == "hard_bounce" do
          DB.execute(
            "UPDATE outbox SET status='failed', last_error='hard bounce' WHERE id=$1 AND status IN ('processing','unknown','pending')",
            [job_id]
          )
        end

        if kind in ["complained", "unsubscribed"] do
          DB.execute("UPDATE contacts SET opted_out_at=COALESCE(opted_out_at,now()) WHERE email=$1", [email])

          DB.execute(
            "UPDATE subscribers s SET state='unsubscribed' FROM contacts c WHERE c.id=s.contact_id AND c.email=$1 AND s.state<>'unsubscribed'",
            [email]
          )
        end

        if kind == "hard_bounce" do
          DB.execute("UPDATE contacts SET bounced_at=COALESCE(bounced_at,now()) WHERE email=$1", [email])
        end

        if kind in ["complained", "unsubscribed", "hard_bounce"] do
          DB.execute(
            "UPDATE outbox o SET status='suppressed' FROM contacts c WHERE c.id=o.contact_id AND c.email=$1 AND o.status='pending' AND o.kind<>'login'",
            [email]
          )
        end

        true
      end
    end)
  end
end
