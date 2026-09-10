import crypto from "node:crypto";

import { pool } from "../config/database.mjs";

/*
 * Stories we have written.
 *
 * The fingerprint is derived from the source URL with tracking parameters
 * stripped, so the same article arriving through two different feed links
 * collapses to one row. It is unique per topic, not per platform: two
 * customers following the same beat should both get the story, each with their
 * own rewrite. What it prevents is one topic covering the same article twice,
 * which is what a reader would experience as the same story coming round again.
 */

export function fingerprint(url) {
  let normalised = String(url ?? "").trim().toLowerCase();

  try {
    const parsed = new URL(normalised);

    /* Campaign parameters differ per feed and say nothing about identity. */
    for (const key of [...parsed.searchParams.keys()]) {
      if (/^(utm_|oc$|oc=|ved$|usg$|gclid$|fbclid$)/.test(key)) {
        parsed.searchParams.delete(key);
      }
    }

    parsed.hash = "";
    normalised = `${parsed.host}${parsed.pathname}${parsed.search}`
      .replace(/\/+$/, "");
  } catch {
    /* Not a URL: hash whatever we were handed rather than throwing. */
  }

  return crypto.createHash("sha256").update(normalised).digest("hex");
}

/*
 * Which of these candidates this topic has already covered. Scoped to the
 * topic, so another customer having written the same article up does not take
 * it away from this one.
 */
export async function alreadyUsed(topicKey, fingerprints) {
  if (!fingerprints.length) return new Set();

  const { rows } = await pool.query(
    `SELECT fingerprint FROM stories
     WHERE topic_key = $1 AND fingerprint = ANY($2::text[])`,
    [topicKey, fingerprints]
  );

  return new Set(rows.map(row => row.fingerprint));
}

/*
 * Writes one story. ON CONFLICT DO NOTHING rather than a prior existence check:
 * two workers can reach the same article for the same topic at the same
 * moment, and the unique index is the only thing that settles it without a
 * race.
 *
 * Returns null when this topic already has that article.
 */
export async function create({
  topicKey,
  issueDate,
  sourceUrl,
  sourceName,
  sourceTitle,
  publishedAt,
  headline,
  standfirst,
  body,
  fingerprint: mark,
  resolvedUrl = null,
  extraction = "headline_only",
  sourceChars = 0,
  verbatimRun = 0
}) {
  const { rows } = await pool.query(
    `INSERT INTO stories(
       topic_key, issue_date, source_url, source_name, source_title,
       published_at, headline, standfirst, body, fingerprint,
       resolved_url, extraction, source_chars, verbatim_run
     )
     VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
     ON CONFLICT(topic_key, fingerprint) DO NOTHING
     RETURNING *`,
    [
      topicKey,
      issueDate,
      sourceUrl,
      sourceName,
      sourceTitle,
      publishedAt,
      headline,
      standfirst,
      body,
      mark,
      resolvedUrl,
      extraction,
      sourceChars,
      verbatimRun
    ]
  );

  return rows[0] ?? null;
}

/* The stories written for a topic on a given day. */
export async function forIssue(topicKey, issueDate) {
  const { rows } = await pool.query(
    `SELECT * FROM stories
     WHERE topic_key = $1 AND issue_date = $2::date
     ORDER BY created_at`,
    [topicKey, issueDate]
  );

  return rows;
}

/* Recent stories, for the public feed and the hosted archive. */
export async function recentForTopic(topicKey, limit = 8) {
  const { rows } = await pool.query(
    `SELECT * FROM stories
     WHERE topic_key = $1
     ORDER BY issue_date DESC, created_at DESC
     LIMIT $2`,
    [topicKey, limit]
  );

  return rows;
}

export async function findById(id) {
  const { rows } = await pool.query(
    "SELECT * FROM stories WHERE id = $1",
    [id]
  );

  return rows[0] ?? null;
}

/*
 * A reader's running order for one issue, cached so a delivery retry does not
 * pay the model again and so a send can be reproduced exactly as it went out.
 */
export async function savePicks({
  contactId,
  topicKey,
  issueDate,
  storyIds,
  reason,
  personalised
}) {
  const { rows } = await pool.query(
    `INSERT INTO newsletter_picks(
       contact_id, topic_key, issue_date, story_ids, reason, personalised
     )
     VALUES($1,$2,$3::date,$4::uuid[],$5,$6)
     ON CONFLICT (contact_id, topic_key, issue_date) DO UPDATE
       SET story_ids = EXCLUDED.story_ids,
           reason = EXCLUDED.reason,
           personalised = EXCLUDED.personalised
     RETURNING *`,
    [contactId, topicKey, issueDate, storyIds, reason ?? null, personalised]
  );

  return rows[0];
}

export async function findPicks(contactId, topicKey, issueDate) {
  const { rows } = await pool.query(
    `SELECT * FROM newsletter_picks
     WHERE contact_id = $1 AND topic_key = $2 AND issue_date = $3::date`,
    [contactId, topicKey, issueDate]
  );

  return rows[0] ?? null;
}

/* ---- editorial content -------------------------------------------------- */

/*
 * The archive holds two kinds of row that are the same kind of page: articles
 * brought over from the Hugo site, and articles this platform writes now. Both
 * are served identically; only their provenance differs.
 */
export const ARCHIVE_ORIGINS = ["import", "editorial"];

/*
 * The twelve languages the imported archive is published in. A path whose
 * first segment is not one of these is not an article URL, which is what keeps
 * /{language}/{category}/{slug} from swallowing every other route.
 */
export const LANGUAGES = [
  "ar", "bn", "en", "es", "fr", "hi",
  "it", "la", "pt", "ru", "ur", "zh"
];

export const isLanguage = value => LANGUAGES.includes(String(value));

export async function findEditorial({ language, slug }) {
  const { rows } = await pool.query(
    `SELECT *, to_char(issue_date, 'YYYY-MM-DD') AS date_slug
     FROM stories
     WHERE origin = ANY($3) AND language = $1 AND slug = $2`,
    [language, slug, ARCHIVE_ORIGINS]
  );

  return rows[0] ?? null;
}

/*
 * The same article in every other language. This is what hreflang needs: each
 * locale is its own page, and the set has to point at itself so search engines
 * treat twelve translations as one article rather than twelve duplicates.
 */
export async function translationsOf(translationKey) {
  if (!translationKey) return [];

  const { rows } = await pool.query(
    `SELECT language, slug, category, headline,
            to_char(issue_date, 'YYYY-MM-DD') AS date_slug
     FROM stories
     WHERE origin = ANY($2) AND translation_key = $1
     ORDER BY language`,
    [translationKey, ARCHIVE_ORIGINS]
  );

  return rows;
}

export async function listEditorial({
  language,
  category = null,
  limit = 30,
  offset = 0
}) {
  const { rows } = await pool.query(
    `SELECT id, language, slug, category, headline, standfirst,
            to_char(issue_date, 'YYYY-MM-DD') AS date_slug
     FROM stories
     WHERE origin = ANY($5)
       AND language = $1
       AND ($2::text IS NULL OR lower(category) = lower($2))
     ORDER BY published_at DESC
     LIMIT $3 OFFSET $4`,
    [language, category, limit, offset, ARCHIVE_ORIGINS]
  );

  return rows;
}

export async function editorialCategories(language) {
  const { rows } = await pool.query(
    `SELECT category, count(*)::int AS n
     FROM stories
     WHERE origin = ANY($2) AND language = $1 AND category IS NOT NULL
     GROUP BY category
     ORDER BY category`,
    [language, ARCHIVE_ORIGINS]
  );

  return rows;
}

/* Every published article, for the sitemap. */
export async function allEditorial(limit = 5000) {
  const { rows } = await pool.query(
    `SELECT language, slug, category, translation_key,
            to_char(issue_date, 'YYYY-MM-DD') AS date_slug
     FROM stories
     WHERE origin = ANY($2)
     ORDER BY published_at DESC
     LIMIT $1`,
    [limit, ARCHIVE_ORIGINS]
  );

  return rows;
}

/*
 * What to read next. Same language, same section, most recent first.
 *
 * The end of an article is where a reader either leaves or continues, and an
 * article that ends in nothing is an article that ends the session. This is
 * what turns the last paragraph into a next page.
 */
export async function relatedTo({ language, category, excludeId, limit = 3 }) {
  const { rows } = await pool.query(
    `SELECT id, language, slug, category, headline, standfirst,
            to_char(issue_date, 'YYYY-MM-DD') AS date_slug,
            length(body) AS body_length
     FROM stories
     WHERE origin = ANY($5)
       AND language = $1
       AND lower(category) = lower($2)
       AND id <> $3
     ORDER BY issue_date DESC, created_at DESC
     LIMIT $4`,
    [language, category ?? "", excludeId, limit, ARCHIVE_ORIGINS]
  );

  return rows;
}

/*
 * Falls back to the rest of the archive when a section is too thin to fill the
 * slots, so the end of an article is never empty.
 */
export async function alsoInLanguage({ language, excludeIds, limit = 3 }) {
  const { rows } = await pool.query(
    `SELECT id, language, slug, category, headline, standfirst,
            to_char(issue_date, 'YYYY-MM-DD') AS date_slug,
            length(body) AS body_length
     FROM stories
     WHERE origin = ANY($4)
       AND language = $1
       AND NOT (id = ANY($2::uuid[]))
     ORDER BY issue_date DESC, created_at DESC
     LIMIT $3`,
    [language, excludeIds, limit, ARCHIVE_ORIGINS]
  );

  return rows;
}

/* Which of these source articles the archive has already covered. */
export async function archiveCovers(fingerprints) {
  if (!fingerprints.length) return new Set();

  const { rows } = await pool.query(
    `SELECT DISTINCT fingerprint FROM stories
     WHERE origin = ANY($2) AND fingerprint = ANY($1::text[])`,
    [fingerprints, ARCHIVE_ORIGINS]
  );

  return new Set(rows.map(row => row.fingerprint));
}

/*
 * One language of one article. The English row carries the source fingerprint
 * so the archive knows the piece has been covered; translations do not, since
 * they are the same coverage rendered again.
 */
export async function createEditorial({
  language,
  slug,
  translationKey,
  category,
  tags = [],
  headline,
  standfirst,
  body,
  publishedAt,
  /*
   * The URL date, given explicitly rather than derived from publishedAt.
   * Casting a timestamptz to a date uses the session timezone, so an article
   * published at midnight UTC lands on the previous day in Los Angeles — and a
   * translation would then sit at a different URL from the article it
   * translates, breaking the hreflang set it belongs to.
   */
  issueDate,
  fingerprint: mark = null,
  sourceUrl = null,
  sourceName = null,
  verbatimRun = 0
}) {
  const { rows } = await pool.query(
    `INSERT INTO stories(
       language, slug, translation_key, category, tags,
       headline, standfirst, body, published_at, issue_date,
       fingerprint, source_url, source_name, verbatim_run, origin
     )
     VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::timestamptz,$14::date,
            $10,$11,$12,$13,'editorial')
     ON CONFLICT (language, slug) WHERE slug IS NOT NULL
     DO NOTHING
     RETURNING *`,
    [
      language, slug, translationKey, category, tags,
      headline, standfirst, body, publishedAt,
      mark, sourceUrl, sourceName, verbatimRun, issueDate
    ]
  );

  return rows[0] ?? null;
}

/* Is this slug taken in any language? Slugs are shared across a translation set. */
export async function slugTaken(slug) {
  const { rows } = await pool.query(
    "SELECT 1 FROM stories WHERE slug = $1 LIMIT 1",
    [slug]
  );

  return rows.length > 0;
}

/*
 * Articles the archive does not hold in every language.
 *
 * The Hugo import brought over 29 groups that were only ever published in
 * eight or ten of the twelve, and a translation that fails during writing
 * leaves the same gap. This is what the translator works through.
 */
export async function missingTranslations({ languages, limit = 50 }) {
  const { rows } = await pool.query(
    `SELECT translation_key,
            array_agg(language ORDER BY language) AS present,
            min(category) AS category,
            min(slug) AS slug
     FROM stories
     WHERE origin = ANY($1) AND translation_key IS NOT NULL
     GROUP BY translation_key
     HAVING NOT (array_agg(language) @> $2::text[])
     ORDER BY min(issue_date) DESC
     LIMIT $3`,
    [ARCHIVE_ORIGINS, languages, limit]
  );

  return rows.map(row => ({
    ...row,
    missing: languages.filter(language => !row.present.includes(language))
  }));
}

/* The best row to translate from: the source language where we have it. */
export async function sourceFor(translationKey, preferred = "en") {
  const { rows } = await pool.query(
    `SELECT *, to_char(issue_date, 'YYYY-MM-DD') AS date_slug
     FROM stories
     WHERE origin = ANY($1) AND translation_key = $2
     ORDER BY (language = $3) DESC, created_at
     LIMIT 1`,
    [ARCHIVE_ORIGINS, translationKey, preferred]
  );

  return rows[0] ?? null;
}

/*
 * Recent archive stories from named sections, in one query, capped per
 * section so a busy section cannot crowd out the rest of a report.
 */
export async function recentBySection({
  language = "en",
  sections,
  perSection = 2
}) {
  if (!sections?.length) return [];

  const { rows } = await pool.query(
    `SELECT * FROM (
       SELECT s.*,
              to_char(s.issue_date, 'YYYY-MM-DD') AS date_slug,
              row_number() OVER (
                PARTITION BY lower(s.category) ORDER BY s.issue_date DESC, s.created_at DESC
              ) AS rank
       FROM stories s
       WHERE s.origin = ANY($1)
         AND s.language = $2
         AND lower(s.category) = ANY($3::text[])
     ) ranked
     WHERE rank <= $4
     ORDER BY issue_date DESC, created_at DESC`,
    [
      ARCHIVE_ORIGINS,
      language,
      sections.map(name => String(name).toLowerCase()),
      perSection
    ]
  );

  return rows;
}
