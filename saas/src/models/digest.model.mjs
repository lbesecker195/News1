import { pool, transaction } from "../config/database.mjs";
import { ACTIVE_BILLING_STATUSES } from "../utils/billing-status.mjs";

/*
 * Claims one tenant that is due today's digest, together with its topic items
 * and confirmed recipients, and runs fn inside the row lock. digest_sent_on is
 * the guard that makes a re-run on the same day a no-op even before the outbox
 * dedupe key gets involved.
 */
export async function withTenantDueForDigest(date, fn) {
  return transaction(async db => {
    const { rows } = await db.query(
      `SELECT t.id, t.name, t.language, t.public_token, t.topic_key,
              p.query AS topic_query,
              COALESCE(p.items,'[]'::jsonb) AS items
       FROM tenants t
       JOIN topics p ON p.key = t.topic_key
       WHERE t.billing_status = ANY($1)
         AND (t.digest_sent_on IS NULL OR t.digest_sent_on < $2::date)
         AND EXISTS (
           SELECT 1 FROM subscribers s
           WHERE s.tenant_id = t.id AND s.state = 'active'
         )
       ORDER BY t.digest_sent_on NULLS FIRST, t.created_at
       LIMIT 1
       FOR UPDATE OF t SKIP LOCKED`,
      [ACTIVE_BILLING_STATUSES, date]
    );

    const tenant = rows[0];

    if (!tenant) return null;

    const recipients = await db.query(
      `SELECT c.id AS contact_id, c.email, c.unsub_token,
              c.name, c.title, c.company, c.industry
       FROM subscribers s
       JOIN contacts c ON c.id = s.contact_id
       WHERE s.tenant_id = $1
         AND s.state = 'active'
         AND c.opted_out_at IS NULL
         AND c.bounced_at IS NULL
       ORDER BY c.email`,
      [tenant.id]
    );

    const result = await fn(
      { ...tenant, recipients: recipients.rows },
      db
    );

    await db.query(
      "UPDATE tenants SET digest_sent_on=$2::date WHERE id=$1",
      [tenant.id, date]
    );

    return result;
  });
}

/* Contacts eligible for an outbound campaign on a given date. */
export async function listCampaignContacts(limit = 500) {
  const { rows } = await pool.query(
    `SELECT id, email, name, company, unsub_token
     FROM contacts
     WHERE opted_out_at IS NULL
       AND bounced_at IS NULL
     ORDER BY created_at
     LIMIT $1`,
    [limit]
  );

  return rows;
}
