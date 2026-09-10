import { pool, transaction } from "../config/database.mjs";
import { HttpError } from "../utils/http-error.mjs";
import { isBillingActive } from "../utils/billing-status.mjs";

/*
 * The stakeholder roster. Ten people from the company are meant to be involved,
 * which is an onboarding requirement rather than a cap on who gets the
 * briefing: the point is to get relevant stakeholders using the product, which
 * is what makes an Enterprise conversation possible later.
 *
 * The owner counts as the first, captured at registration. The other nine are
 * collected after payment, so buying is never blocked on filling in a roster.
 */
export const REQUIRED_STAKEHOLDERS = 10;

export async function countForTenant(tenantId) {
  const { rows } = await pool.query(
    `SELECT count(*)::int AS n
     FROM subscribers
     WHERE tenant_id=$1 AND state <> 'unsubscribed'`,
    [tenantId]
  );

  return rows[0].n;
}

/*
 * The owner is stakeholder one. They asked for the service and are paying for
 * it, so they are enrolled already confirmed rather than being sent an
 * invitation to a thing they just bought. Idempotent: it runs on activation and
 * again on every renewal.
 */
export async function enrolOwner(db, tenantId, email) {
  const contact = await db.query(
    `INSERT INTO contacts(email)
     VALUES($1)
     ON CONFLICT(email) DO UPDATE SET email=EXCLUDED.email
     RETURNING id, opted_out_at, bounced_at`,
    [email]
  );

  const { id, opted_out_at: optedOut, bounced_at: bounced } = contact.rows[0];

  /* An owner who has opted out stays opted out; that choice is theirs. */
  if (optedOut || bounced) return false;

  const { rowCount } = await db.query(
    `INSERT INTO subscribers(tenant_id, contact_id, state, confirmed_at)
     VALUES($1,$2,'active',now())
     ON CONFLICT ON CONSTRAINT subscribers_tenant_contact_key DO NOTHING`,
    [tenantId, id]
  );

  return rowCount > 0;
}

export async function listForTenant(tenantId) {
  const { rows } = await pool.query(
    `SELECT c.email, s.state
     FROM subscribers s
     JOIN contacts c ON c.id=s.contact_id
     WHERE s.tenant_id=$1
     ORDER BY c.email`,
    [tenantId]
  );

  return rows;
}

/*
 * Adds a recipient on the customer's own authority.
 *
 * There is no confirmation email: the customer attests that they may mail this
 * person, and that attestation is stored against the row. What protects the
 * recipient instead is everything downstream — a one-click unsubscribe in every
 * issue, platform-wide suppression on opt-out or bounce, and the fact that a
 * suppressed address can never be re-added by anyone.
 *
 * One transaction, so a crash cannot record a recipient the customer was never
 * recorded as having authorised.
 */
export async function addRecipient({
  tenantId,
  email,
  authorisedBy
}) {
  return transaction(async db => {
    const tenantResult = await db.query(
      "SELECT * FROM tenants WHERE id=$1 FOR UPDATE",
      [tenantId]
    );

    const tenant = tenantResult.rows[0];

    if (!tenant || !isBillingActive(tenant.billing_status)) {
      throw new HttpError(402, "Activate your subscription first.");
    }

    const contactResult = await db.query(
      `INSERT INTO contacts(email)
       VALUES($1)
       ON CONFLICT(email)
       DO UPDATE SET email=EXCLUDED.email
       RETURNING *`,
      [email]
    );

    const contact = contactResult.rows[0];

    /*
     * A suppression outranks any attestation. Someone who has opted out or hard
     * bounced stays off the list no matter who says they may be mailed.
     */
    if (contact.opted_out_at || contact.bounced_at) {
      throw new HttpError(
        409,
        "This address is suppressed and cannot be added."
      );
    }

    const added = await db.query(
      `INSERT INTO subscribers(
         tenant_id, contact_id, state, confirmed_at, authorised_at, authorised_by
       )
       VALUES($1,$2,'active',now(),now(),$3)
       ON CONFLICT ON CONSTRAINT subscribers_tenant_contact_key
       DO UPDATE SET
         state='active',
         confirmed_at=now(),
         authorised_at=now(),
         authorised_by=EXCLUDED.authorised_by
       WHERE subscribers.state='unsubscribed'
       RETURNING id`,
      [tenantId, contact.id, authorisedBy ?? tenant.owner_email]
    );

    if (!added.rows[0]) {
      throw new HttpError(409, "This recipient is already on your list.");
    }

    return added.rows[0].id;
  });
}

export async function remove(tenantId, email) {
  const { rowCount } = await pool.query(
    `DELETE FROM subscribers s
     USING contacts c
     WHERE s.contact_id=c.id
       AND s.tenant_id=$1
       AND c.email=$2`,
    [tenantId, email]
  );

  return rowCount > 0;
}

export async function confirm(confirmToken) {
  const result = await pool.query(
    `UPDATE subscribers s
     SET state='active', confirmed_at=now()
     FROM contacts c
     WHERE s.contact_id=c.id
       AND s.confirm_token=$1
       AND s.confirm_expires_at>now()
       AND s.state<>'unsubscribed'
       AND c.opted_out_at IS NULL
       AND c.bounced_at IS NULL
     RETURNING s.tenant_id`,
    [confirmToken]
  );

  return result.rowCount > 0;
}

/*
 * An opt-out is recorded against the contact, so it holds across every tenant
 * that has ever mailed this address, and it retracts mail that is already
 * queued but not yet sent.
 */
export async function unsubscribe(unsubscribeToken) {
  return transaction(async db => {
    const result = await db.query(
      `UPDATE contacts
       SET opted_out_at=COALESCE(opted_out_at,now())
       WHERE unsub_token=$1
       RETURNING id`,
      [unsubscribeToken]
    );

    if (!result.rows[0]) return false;

    const contactId = result.rows[0].id;

    await db.query(
      `UPDATE subscribers SET state='unsubscribed'
       WHERE contact_id=$1 AND state<>'unsubscribed'`,
      [contactId]
    );

    await db.query(
      `UPDATE outbox SET status='suppressed'
       WHERE contact_id=$1
         AND status='pending'
         AND kind<>'login'`,
      [contactId]
    );

    return true;
  });
}
