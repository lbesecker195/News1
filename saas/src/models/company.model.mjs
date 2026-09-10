import { pool, transaction } from "../config/database.mjs";
import { ACTIVE_BILLING_STATUSES } from "../utils/billing-status.mjs";
import { REQUIRED_STAKEHOLDERS } from "./subscriber.model.mjs";

/*
 * Topics are shared across tenants: the key is a hash of language plus query,
 * so two companies watching the same terms are crawled once.
 */
export async function saveSettings(tenantId, input, topic) {
  await transaction(async db => {
    await db.query(
      `INSERT INTO topics(key,query,language)
       VALUES($1,$2,$3)
       ON CONFLICT(key) DO NOTHING`,
      [topic.key, topic.query, input.language]
    );

    await db.query(
      `UPDATE tenants SET
         name=$1,
         domain=$2,
         industry=$3,
         keywords=$4,
         language=$5,
         topic_key=$6
       WHERE id=$7`,
      [
        input.name,
        input.domain,
        input.industry,
        JSON.stringify(input.keywords),
        input.language,
        topic.key,
        tenantId
      ]
    );
  });
}

export async function findPreview(topicKey) {
  if (!topicKey) {
    return { items: [], refreshed_at: null };
  }

  const { rows } = await pool.query(
    `SELECT COALESCE(items,'[]'::jsonb) AS items, refreshed_at
     FROM topics WHERE key=$1`,
    [topicKey]
  );

  return rows[0] || {
    items: [],
    refreshed_at: null
  };
}

/*
 * The public feed, embed and hosted-article routes all resolve through here, so
 * a lapsed subscription takes the published feed down with it.
 *
 * The stakeholder count comes back with the row rather than gating the query:
 * a tenant who is paying but has not finished onboarding needs a different
 * answer from one who does not exist, and only the caller can say which.
 */
export async function findPublicTenant(publicToken) {
  const { rows } = await pool.query(
    `SELECT t.*, COALESCE(p.items,'[]'::jsonb) AS items, p.refreshed_at,
            (
              SELECT count(*)::int FROM subscribers s
              WHERE s.tenant_id = t.id AND s.state <> 'unsubscribed'
            ) AS stakeholder_count
     FROM tenants t
     JOIN topics p ON p.key=t.topic_key
     WHERE t.public_token=$1
       AND t.billing_status = ANY($2)`,
    [publicToken, ACTIVE_BILLING_STATUSES]
  );

  return rows[0] || null;
}

/*
 * Serialises the PayPal dance for one tenant. Subscribing and cancelling both
 * read-modify-write the same row, and without the lock a double-clicked
 * Activate button creates two PayPal subscriptions for one company.
 */
export async function withBillingLock(tenantId, fn) {
  return transaction(async db => {
    const { rows } = await db.query(
      "SELECT * FROM tenants WHERE id=$1 FOR UPDATE",
      [tenantId]
    );

    return fn(rows[0], db);
  });
}

/* Records the subscription the tenant is about to approve at PayPal. */
export async function setSubscription(db, tenantId, subscriptionId, status) {
  await db.query(
    `UPDATE tenants SET paypal_subscription_id=$1, billing_status=$2
     WHERE id=$3`,
    [subscriptionId, status, tenantId]
  );
}

export async function setBillingStatus(db, tenantId, subscriptionId, status) {
  await db.query(
    `UPDATE tenants SET billing_status=$2
     WHERE id=$1 AND paypal_subscription_id=$3`,
    [tenantId, status, subscriptionId]
  );
}

/*
 * Applies a webhook to whichever tenant owns the subscription. Keyed on the
 * subscription id rather than on a tenant id read out of the event, so a forged
 * custom_id cannot move someone else's subscription onto the attacker's tenant.
 * Returns false when no tenant owns it, which is worth logging.
 */
export async function syncSubscription({ subscriptionId, status }) {
  const { rowCount } = await pool.query(
    `UPDATE tenants SET billing_status=$2
     WHERE paypal_subscription_id=$1`,
    [subscriptionId, status]
  );

  return rowCount > 0;
}

/* Runs fn with the tenant that owns a PayPal subscription, inside its lock. */
export async function withOwnerOfSubscription(subscriptionId, fn) {
  return transaction(async db => {
    const { rows } = await db.query(
      "SELECT * FROM tenants WHERE paypal_subscription_id=$1 FOR UPDATE",
      [subscriptionId]
    );

    return rows[0] ? fn(rows[0], db) : null;
  });
}

/*
 * Every tenant whose feed is actually live: paying, and past the stakeholder
 * gate. This is what the sitemap is built from, so an unpublished feed is
 * never advertised to a crawler.
 */
export async function listPublished(limit = 500) {
  const { rows } = await pool.query(
    `SELECT t.public_token, t.topic_key, t.name
     FROM tenants t
     WHERE t.billing_status = ANY($1)
       AND t.topic_key IS NOT NULL
       AND (
         SELECT count(*) FROM subscribers s
         WHERE s.tenant_id = t.id AND s.state <> 'unsubscribed'
       ) >= $2
     ORDER BY t.created_at
     LIMIT $3`,
    [ACTIVE_BILLING_STATUSES, REQUIRED_STAKEHOLDERS, limit]
  );

  return rows;
}
