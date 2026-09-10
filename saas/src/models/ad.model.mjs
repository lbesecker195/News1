import { pool, transaction } from "../config/database.mjs";

/*
 * Ad selection and delivery accounting.
 *
 * Targeting is matched in SQL rather than in JavaScript so that a large
 * campaign book stays one indexed query per slot instead of loading every
 * campaign into the process on every send.
 */

/*
 * Campaigns eligible for one reader, best first.
 *
 * A campaign matches when every dimension it restricts matches the reader.
 * An absent or empty dimension restricts nothing — that is what makes an
 * untargeted campaign run everywhere.
 *
 * Title patterns are SQL LIKE patterns ("%vp%"), matched case-insensitively,
 * because job titles are free text and nobody agrees how to write them.
 */
export async function eligibleCreatives({
  slot,
  issueDate,
  title,
  industry,
  topicTerms = []
}) {
  const { rows } = await pool.query(
    `SELECT cr.id AS creative_id, cr.campaign_id, cr.slot, cr.headline,
            cr.body, cr.cta, cr.image_url, cr.click_url, cr.weight
     FROM creatives cr
     JOIN campaigns c ON c.id = cr.campaign_id
     JOIN advertisers a ON a.id = c.advertiser_id
     WHERE cr.active
       AND a.active
       AND c.status = 'active'
       AND cr.slot = $1
       AND $2::date BETWEEN c.starts_on AND c.ends_on

       -- Caps. 0 means uncapped.
       AND (c.total_cap = 0 OR c.impressions < c.total_cap)
       AND (
         c.daily_cap = 0
         OR (
           SELECT count(*) FROM ad_placements p
           WHERE p.campaign_id = c.id AND p.issue_date = $2::date
         ) < c.daily_cap
       )

       -- Job title, matched case-insensitively against LIKE patterns.
       AND (
         c.targeting->'titles' IS NULL
         OR jsonb_array_length(COALESCE(c.targeting->'titles', '[]'::jsonb)) = 0
         OR (
           $3::text IS NOT NULL AND EXISTS (
             SELECT 1
             FROM jsonb_array_elements_text(c.targeting->'titles') AS t(pattern)
             WHERE lower($3::text) LIKE lower(t.pattern)
           )
         )
       )

       -- Reader industry, matched exactly but case-insensitively.
       AND (
         c.targeting->'industries' IS NULL
         OR jsonb_array_length(COALESCE(c.targeting->'industries', '[]'::jsonb)) = 0
         OR (
           $4::text IS NOT NULL AND EXISTS (
             SELECT 1
             FROM jsonb_array_elements_text(c.targeting->'industries') AS i(name)
             WHERE lower(i.name) = lower($4::text)
           )
         )
       )

       -- Contextual: the topic terms this issue is about.
       AND (
         c.targeting->'topics' IS NULL
         OR jsonb_array_length(COALESCE(c.targeting->'topics', '[]'::jsonb)) = 0
         OR EXISTS (
           SELECT 1
           FROM jsonb_array_elements_text(c.targeting->'topics') AS k(term)
           WHERE lower(k.term) = ANY($5::text[])
         )
       )

     /*
      * Better-paying and more specific campaigns first, then weight. The
      * random tail spreads delivery across creatives that tie, so one does not
      * monopolise a slot for an entire send.
      */
     ORDER BY c.cpm_cents DESC,
              jsonb_array_length(COALESCE(c.targeting->'titles','[]'::jsonb)) DESC,
              cr.weight DESC,
              random()
     LIMIT 10`,
    [
      slot,
      issueDate,
      title ?? null,
      industry ?? null,
      topicTerms.map(term => String(term).toLowerCase())
    ]
  );

  return rows;
}

/*
 * Records that a creative was placed in someone's issue and returns the row id,
 * which becomes the opaque token in the pixel and click URLs.
 *
 * The impression counter moves at send time rather than on pixel load: images
 * are blocked often enough that counting only loaded pixels would under-report
 * delivery by more than it would over-report it. The ad_events ledger keeps the
 * verified opens separately, so both numbers are available.
 */
export async function recordPlacement(db, {
  campaignId,
  creativeId,
  contactId,
  tenantId,
  issueDate,
  slot
}) {
  const { rows } = await db.query(
    `INSERT INTO ad_placements(
       campaign_id, creative_id, contact_id, tenant_id, issue_date, slot
     )
     VALUES($1,$2,$3,$4,$5,$6)
     RETURNING id`,
    [campaignId, creativeId, contactId, tenantId, issueDate, slot]
  );

  await db.query(
    "UPDATE campaigns SET impressions = impressions + 1 WHERE id = $1",
    [campaignId]
  );

  return rows[0].id;
}

/*
 * A pixel load. first_seen is set once; the ledger takes every hit, so a reader
 * who opens an issue four times shows one confirmed open and four events.
 */
export async function recordImpression(placementId) {
  return transaction(async db => {
    const { rows } = await db.query(
      `UPDATE ad_placements
       SET first_seen = COALESCE(first_seen, now())
       WHERE id = $1
       RETURNING campaign_id`,
      [placementId]
    );

    if (!rows[0]) return false;

    await db.query(
      "INSERT INTO ad_events(placement_id, campaign_id, kind) VALUES($1,$2,'impression')",
      [placementId, rows[0].campaign_id]
    );

    return true;
  });
}

/* A click. Returns the destination so the route can redirect to it. */
export async function recordClick(placementId) {
  return transaction(async db => {
    const { rows } = await db.query(
      `UPDATE ad_placements p
       SET first_click = COALESCE(p.first_click, now())
       FROM creatives cr
       WHERE p.id = $1 AND cr.id = p.creative_id
       RETURNING p.campaign_id, cr.click_url`,
      [placementId]
    );

    if (!rows[0]) return null;

    await db.query(
      "INSERT INTO ad_events(placement_id, campaign_id, kind) VALUES($1,$2,'click')",
      [placementId, rows[0].campaign_id]
    );

    await db.query(
      "UPDATE campaigns SET clicks = clicks + 1 WHERE id = $1",
      [rows[0].campaign_id]
    );

    return rows[0].click_url;
  });
}

/* Campaigns whose flight has ended stop being considered. */
export async function completeFinishedCampaigns() {
  const { rowCount } = await pool.query(
    `UPDATE campaigns SET status = 'completed'
     WHERE status = 'active'
       AND (
         ends_on < current_date
         OR (total_cap > 0 AND impressions >= total_cap)
       )`
  );

  return rowCount;
}

/* Delivery report: what ran, how it performed, and what it is worth. */
export async function campaignReport(campaignId = null) {
  const { rows } = await pool.query(
    `SELECT c.id, a.name AS advertiser, c.name, c.status,
            c.starts_on, c.ends_on, c.cpm_cents,
            c.impressions, c.clicks,
            count(p.id) FILTER (WHERE p.first_seen IS NOT NULL)::int AS confirmed_opens,
            round(c.impressions * c.cpm_cents / 1000.0)::int AS revenue_cents
     FROM campaigns c
     JOIN advertisers a ON a.id = c.advertiser_id
     LEFT JOIN ad_placements p ON p.campaign_id = c.id
     WHERE ($1::uuid IS NULL OR c.id = $1)
     GROUP BY c.id, a.name
     ORDER BY c.starts_on DESC`,
    [campaignId]
  );

  return rows;
}
