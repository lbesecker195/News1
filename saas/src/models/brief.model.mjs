import { pool } from "../config/database.mjs";

export async function findUnexpired(id) {
  const { rows } = await pool.query(
    `SELECT b.id, b.html, b.has_pdf, b.story_ids, b.meta, b.contact_id,
            to_char(b.issue_date, 'YYYY-MM-DD') AS date_slug,
            t.name AS company, t.domain, t.industry, t.keywords,
            t.public_token,
            (
              SELECT count(*)::int FROM subscribers s
              WHERE s.tenant_id = t.id AND s.state <> 'unsubscribed'
            ) AS stakeholder_count
     FROM briefs b
     LEFT JOIN tenants t ON t.id = b.tenant_id
     WHERE b.id=$1 AND b.expires_at>now()`,
    [id]
  );

  return rows[0] || null;
}

/* The stories in a brief, in the order they were selected. */
export async function storiesFor(brief) {
  if (!brief.story_ids?.length) return [];

  const { rows } = await pool.query(
    `SELECT *, to_char(issue_date, 'YYYY-MM-DD') AS date_slug
     FROM stories WHERE id = ANY($1::uuid[])`,
    [brief.story_ids]
  );

  const byId = new Map(rows.map(row => [row.id, row]));

  return brief.story_ids.map(id => byId.get(id)).filter(Boolean);
}

/*
 * One brief per tenant per day, shared by every recipient of that day's
 * digest, so the hosted page and the PDF are generated once.
 */
export async function create(db, {
  tenantId = null,
  html,
  storyIds = [],
  issueDate,
  contactId = null,
  meta = {}
}) {
  const { rows } = await db.query(
    `INSERT INTO briefs(
       tenant_id, html, story_ids, issue_date, contact_id, meta
     )
     VALUES($1,$2,$3::uuid[],$4::date,$5,$6)
     RETURNING id`,
    [tenantId, html, storyIds, issueDate, contactId, JSON.stringify(meta)]
  );

  return rows[0].id;
}

export async function markPdfWritten(id) {
  await pool.query(
    "UPDATE briefs SET has_pdf=true WHERE id=$1",
    [id]
  );
}

/*
 * Returns the ids that were removed so the caller can delete the matching PDF
 * files; the rows are gone either way.
 */
export async function deleteExpired(limit = 500) {
  const { rows } = await pool.query(
    `DELETE FROM briefs
     WHERE id IN (
       SELECT id FROM briefs WHERE expires_at<=now() LIMIT $1
     )
     RETURNING id, has_pdf`,
    [limit]
  );

  return rows;
}
