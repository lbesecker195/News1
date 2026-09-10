import { pool } from "../config/database.mjs";

/*
 * Claims the topic most overdue for a crawl by pushing its next refresh out,
 * so the row is leased rather than locked. The crawl that follows makes an
 * HTTP call to Google News and a second one to OpenAI; holding an open
 * transaction and a pool connection across both would be a slow leak under
 * any real number of topics.
 *
 * If the worker dies mid-crawl the lease simply expires and the topic is
 * picked up again.
 */
export async function claimStaleTopic(leaseMinutes = 10) {
  const { rows } = await pool.query(
    `UPDATE topics SET refresh_after = now() + ($1 || ' minutes')::interval
     WHERE key = (
       SELECT key FROM topics
       WHERE refresh_after <= now()
       ORDER BY refresh_after
       LIMIT 1
       FOR UPDATE SKIP LOCKED
     )
     RETURNING key, query, language, COALESCE(items,'[]'::jsonb) AS items`,
    [String(leaseMinutes)]
  );

  return rows[0] || null;
}

export async function saveItems(key, items, refreshInterval = "1 hour") {
  await pool.query(
    `UPDATE topics SET
       items=$2,
       refreshed_at=now(),
       refresh_after=now() + $3::interval,
       last_error=NULL
     WHERE key=$1`,
    [key, JSON.stringify(items), refreshInterval]
  );
}

/*
 * A failed crawl backs the topic off rather than leaving it at the head of the
 * queue, where it would be retried in a tight loop.
 */
export async function recordFailure(key, message, retryInterval = "15 minutes") {
  await pool.query(
    `UPDATE topics SET
       refresh_after=now() + $3::interval,
       last_error=$2
     WHERE key=$1`,
    [key, String(message).slice(0, 500), retryInterval]
  );
}

/*
 * A topic nobody watches any more stops costing crawls. Kept simple: the row
 * itself stays, so a tenant returning to the same keywords keeps its history.
 */
export async function parkUnused() {
  const { rowCount } = await pool.query(
    `UPDATE topics SET refresh_after = now() + interval '30 days'
     WHERE refresh_after <= now() + interval '1 hour'
       AND NOT EXISTS (
         SELECT 1 FROM tenants t WHERE t.topic_key = topics.key
       )`
  );

  return rowCount;
}
