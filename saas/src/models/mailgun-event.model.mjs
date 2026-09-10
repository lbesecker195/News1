import { transaction } from "../config/database.mjs";

/*
 * Mailgun retries webhooks, so the event id is the idempotency key: the insert
 * either wins and applies the side effects, or loses and does nothing. Both
 * halves share one transaction so a redelivery can never double-apply.
 */
export async function recordAndApply({
  id,
  kind,
  jobId,
  email
}) {
  return transaction(async db => {
    const inserted = await db.query(
      `INSERT INTO mailgun_events(id,kind,job_id)
       VALUES($1,$2,$3)
       ON CONFLICT(id) DO NOTHING
       RETURNING id`,
      [id, kind, jobId]
    );

    if (!inserted.rowCount) return false;

    if (jobId && ["accepted", "delivered"].includes(kind)) {
      await db.query(
        `UPDATE outbox SET status='accepted'
         WHERE id=$1
           AND status IN ('processing','unknown','pending')`,
        [jobId]
      );
    }

    /*
     * A permanent failure is only recorded against the job when Mailgun tells
     * us which job it was; the contact-level suppression below is what
     * actually protects the sending domain.
     */
    if (jobId && kind === "hard_bounce") {
      await db.query(
        `UPDATE outbox SET status='failed', last_error='hard bounce'
         WHERE id=$1
           AND status IN ('processing','unknown','pending')`,
        [jobId]
      );
    }

    if (["complained", "unsubscribed"].includes(kind)) {
      await db.query(
        `UPDATE contacts
         SET opted_out_at=COALESCE(opted_out_at,now())
         WHERE email=$1`,
        [email]
      );

      await db.query(
        `UPDATE subscribers s SET state='unsubscribed'
         FROM contacts c
         WHERE c.id=s.contact_id
           AND c.email=$1
           AND s.state<>'unsubscribed'`,
        [email]
      );
    }

    if (kind === "hard_bounce") {
      await db.query(
        `UPDATE contacts
         SET bounced_at=COALESCE(bounced_at,now())
         WHERE email=$1`,
        [email]
      );
    }

    /* Stop anything still queued for an address we must no longer mail. */
    if (["complained", "unsubscribed", "hard_bounce"].includes(kind)) {
      await db.query(
        `UPDATE outbox o SET status='suppressed'
         FROM contacts c
         WHERE c.id=o.contact_id
           AND c.email=$1
           AND o.status='pending'
           AND o.kind<>'login'`,
        [email]
      );
    }

    return true;
  });
}
