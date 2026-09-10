import { pool } from "../config/database.mjs";

export const MAX_ATTEMPTS = 5;

/*
 * Claims exactly one job. SKIP LOCKED lets several delivery loops share the
 * queue, and the status flip to 'processing' inside the same statement means a
 * crash after this point leaves a row that maintenance can recover rather than
 * one that is silently sent twice.
 */
export async function claimJob() {
  const { rows } = await pool.query(
    `UPDATE outbox SET
       status='processing',
       attempts=attempts+1,
       locked_at=now()
     WHERE id = (
       SELECT id FROM outbox
       WHERE status='pending'
         AND run_after <= now()
         AND (expires_at IS NULL OR expires_at > now())
       ORDER BY run_after
       LIMIT 1
       FOR UPDATE SKIP LOCKED
     )
     RETURNING *`
  );

  return rows[0] || null;
}

export async function markAccepted(id, providerMessageId) {
  await pool.query(
    `UPDATE outbox SET status='accepted', provider_message_id=$2, last_error=NULL
     WHERE id=$1`,
    [id, providerMessageId]
  );
}

/*
 * The send left this process but the outcome is unknown. Never retried: the
 * Mailgun events webhook resolves it to 'accepted', or maintenance ages it out.
 */
export async function markUnknown(id, message) {
  await pool.query(
    "UPDATE outbox SET status='unknown', last_error=$2 WHERE id=$1",
    [id, String(message).slice(0, 500)]
  );
}

export async function markFailed(id, message) {
  await pool.query(
    "UPDATE outbox SET status='failed', last_error=$2 WHERE id=$1",
    [id, String(message).slice(0, 500)]
  );
}

export async function markSuppressed(id, message) {
  await pool.query(
    "UPDATE outbox SET status='suppressed', last_error=$2 WHERE id=$1",
    [id, String(message).slice(0, 500)]
  );
}

/* Exponential backoff, capped, with the attempt count already incremented. */
export async function retryLater(id, attempts, message) {
  const minutes = Math.min(60, 2 ** Math.max(0, attempts - 1));

  await pool.query(
    `UPDATE outbox SET
       status='pending',
       run_after=now() + ($2 || ' minutes')::interval,
       last_error=$3
     WHERE id=$1`,
    [id, String(minutes), String(message).slice(0, 500)]
  );
}

/*
 * Puts a claimed job back without spending an attempt. Used when the reason
 * for not sending is about the sender, not the message — a paused campaign,
 * for instance — so the job is not eventually failed for it.
 */
export async function deferJob(id, minutes, reason) {
  await pool.query(
    `UPDATE outbox SET
       status='pending',
       run_after=now() + ($2 || ' minutes')::interval,
       attempts=GREATEST(attempts - 1, 0),
       last_error=$3
     WHERE id=$1`,
    [id, String(minutes), String(reason).slice(0, 500)]
  );
}

/*
 * A job that is still 'processing' long after it was claimed belongs to a
 * worker that died. Returning it to 'pending' is safe because a send that did
 * reach Mailgun would have moved the row on before the timeout.
 */
export async function requeueStuck(olderThanMinutes = 15) {
  const { rowCount } = await pool.query(
    `UPDATE outbox SET status='pending', locked_at=NULL
     WHERE status='processing'
       AND locked_at < now() - ($1 || ' minutes')::interval
       AND attempts < $2`,
    [String(olderThanMinutes), MAX_ATTEMPTS]
  );

  return rowCount;
}

export async function failExhausted() {
  const { rowCount } = await pool.query(
    `UPDATE outbox SET status='failed',
       last_error=COALESCE(last_error,'attempts exhausted')
     WHERE status='processing'
       AND locked_at < now() - interval '15 minutes'
       AND attempts >= $1`,
    [MAX_ATTEMPTS]
  );

  return rowCount;
}

/* A login link that is queued past its own expiry must never be sent. */
export async function expireStale() {
  const { rowCount } = await pool.query(
    `UPDATE outbox SET status='expired'
     WHERE status IN ('pending','unknown')
       AND expires_at IS NOT NULL
       AND expires_at <= now()`
  );

  return rowCount;
}

export async function prune(days = 60) {
  const { rowCount } = await pool.query(
    `DELETE FROM outbox
     WHERE status IN ('accepted','failed','suppressed','expired')
       AND created_at < now() - ($1 || ' days')::interval`,
    [String(days)]
  );

  return rowCount;
}

export async function pruneAuth() {
  await pool.query("DELETE FROM login_tokens WHERE expires_at <= now()");
  await pool.query("DELETE FROM sessions WHERE expires_at <= now()");
}

export async function pruneEvents(days = 30) {
  const { rowCount } = await pool.query(
    `DELETE FROM mailgun_events
     WHERE received_at < now() - ($1 || ' days')::interval`,
    [String(days)]
  );

  return rowCount;
}
