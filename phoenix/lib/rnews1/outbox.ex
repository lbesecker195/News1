defmodule Rnews1.Outbox do
  @moduledoc "The mail queue: claimed with SKIP LOCKED, moved through a small status machine."
  alias Rnews1.DB

  @max_attempts 5
  def max_attempts, do: @max_attempts

  @doc "The one place outgoing mail is created. dedupe_key makes re-running a scheduler harmless."
  def enqueue(%{to_email: to_email, kind: kind} = a) do
    DB.value(
      """
      INSERT INTO outbox(tenant_id, contact_id, to_email, kind, payload, run_after, expires_at, dedupe_key)
      VALUES($1,$2,$3,$4,$5,COALESCE($6,now()),$7,$8)
      ON CONFLICT (dedupe_key) DO NOTHING
      RETURNING id
      """,
      [
        Map.get(a, :tenant_id),
        Map.get(a, :contact_id),
        to_email,
        kind,
        Map.get(a, :payload, %{}),
        Map.get(a, :run_after),
        Map.get(a, :expires_at),
        Map.get(a, :dedupe_key)
      ]
    )
  end

  def claim_job do
    DB.one("""
    UPDATE outbox SET status='processing', attempts=attempts+1, locked_at=now()
    WHERE id = (
      SELECT id FROM outbox WHERE status='pending' AND run_after <= now() AND (expires_at IS NULL OR expires_at > now())
      ORDER BY run_after LIMIT 1 FOR UPDATE SKIP LOCKED
    ) RETURNING *
    """)
  end

  def mark_accepted(id, provider_message_id) do
    DB.execute("UPDATE outbox SET status='accepted', provider_message_id=$2, last_error=NULL WHERE id=$1", [
      id,
      provider_message_id
    ])
  end

  def mark_unknown(id, message), do: mark(id, "unknown", message)
  def mark_failed(id, message), do: mark(id, "failed", message)
  def mark_suppressed(id, message), do: mark(id, "suppressed", message)

  defp mark(id, status, message) do
    DB.execute("UPDATE outbox SET status=$3, last_error=$2 WHERE id=$1", [id, snip(message), status])
  end

  def retry_later(id, attempts, message) do
    minutes = min(60, Integer.pow(2, max(0, attempts - 1)))

    DB.execute(
      "UPDATE outbox SET status='pending', run_after=now() + ($2 || ' minutes')::interval, last_error=$3 WHERE id=$1",
      [id, to_string(minutes), snip(message)]
    )
  end

  def defer_job(id, minutes, reason) do
    DB.execute(
      """
      UPDATE outbox SET status='pending', run_after=now() + ($2 || ' minutes')::interval,
        attempts=GREATEST(attempts - 1, 0), last_error=$3 WHERE id=$1
      """,
      [id, to_string(minutes), snip(reason)]
    )
  end

  def requeue_stuck(older_than_minutes \\ 15) do
    DB.execute(
      """
      UPDATE outbox SET status='pending', locked_at=NULL
      WHERE status='processing' AND locked_at < now() - ($1 || ' minutes')::interval AND attempts < $2
      """,
      [to_string(older_than_minutes), @max_attempts]
    )
  end

  def fail_exhausted do
    DB.execute(
      """
      UPDATE outbox SET status='failed', last_error=COALESCE(last_error,'attempts exhausted')
      WHERE status='processing' AND locked_at < now() - interval '15 minutes' AND attempts >= $1
      """,
      [@max_attempts]
    )
  end

  def expire_stale do
    DB.execute(
      "UPDATE outbox SET status='expired' WHERE status IN ('pending','unknown') AND expires_at IS NOT NULL AND expires_at <= now()"
    )
  end

  def prune(days \\ 60) do
    DB.execute(
      "DELETE FROM outbox WHERE status IN ('accepted','failed','suppressed','expired') AND created_at < now() - ($1 || ' days')::interval",
      [to_string(days)]
    )
  end

  def prune_auth do
    DB.execute("DELETE FROM login_tokens WHERE expires_at <= now()")
    DB.execute("DELETE FROM sessions WHERE expires_at <= now()")
  end

  def prune_events(days \\ 30) do
    DB.execute("DELETE FROM mailgun_events WHERE received_at < now() - ($1 || ' days')::interval", [to_string(days)])
  end

  defp snip(message), do: message |> to_string() |> String.slice(0, 500)
end
