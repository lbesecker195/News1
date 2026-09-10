#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";

import YAML from "yaml";

import { pool } from "../src/config/database.mjs";
import { requireEnv } from "../src/config/env.mjs";

/*
 * Brings the Hugo site's articles into Postgres.
 *
 *   npm run import-hugo -- ../hugo/content
 *   npm run import-hugo -- ../hugo/content --dry-run
 *
 * Locales stay separate, which is the point. Each language is its own row with
 * its own slug and its own URL; `translation_key` links the set so every page
 * can declare its siblings with hreflang. Twelve rows per article, not one row
 * with twelve bodies.
 *
 * Grouping is by filename slug rather than the frontmatter's translationKey,
 * because only 822 of 1,818 files carry one while every file has a slug — and
 * where both exist they agree. Hugo itself falls back the same way.
 *
 * Re-running updates in place: the unique index on (language, slug) turns a
 * second import into an update, so this is safe to run after editing content.
 */

/* Directory names under content/ that are languages rather than sections. */
const LANGUAGES = new Set([
  "ar", "bn", "en", "es", "fr", "hi",
  "it", "la", "pt", "ru", "ur", "zh"
]);

async function main() {
  requireEnv("databaseUrl");

  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const root = args.find(arg => !arg.startsWith("--"));

  if (!root) {
    throw new Error(
      "Usage: npm run import-hugo -- ../hugo/content [--dry-run]"
    );
  }

  const files = await walk(path.resolve(root));

  const parsed = [];
  const skipped = [];

  for (const file of files) {
    try {
      const article = await read(file, root);

      if (article) parsed.push(article);
      else skipped.push({ file, reason: "not an article" });
    } catch (error) {
      skipped.push({ file, reason: error.message });
    }
  }

  /* Group by slug so the summary can report coverage per article. */
  const groups = new Map();

  for (const article of parsed) {
    if (!groups.has(article.slug)) groups.set(article.slug, []);
    groups.get(article.slug).push(article.language);
  }

  const summary = {
    files: files.length,
    articles: parsed.length,
    translationGroups: groups.size,
    languages: [...new Set(parsed.map(a => a.language))].sort().join(" "),
    skipped: skipped.length,
    /* Parsed only after dropping an unterminated `tweet:` line. */
    recoveredFromBadYaml: recovered.length,
    written: 0
  };

  if (dryRun) {
    console.log({ ...summary, dryRun: true });
    report(groups, skipped);
    return;
  }

  for (const article of parsed) {
    await upsert(article);
    summary.written++;
  }

  console.log(summary);
  report(groups, skipped);
}

function report(groups, skipped) {
  const partial = [...groups.entries()]
    .filter(([, languages]) => languages.length < 12)
    .sort((a, b) => a[1].length - b[1].length);

  if (partial.length) {
    console.log(`\n${partial.length} article(s) not in all 12 languages:`);

    for (const [slug, languages] of partial.slice(0, 10)) {
      console.log(`  ${languages.length}/12  ${slug}`);
    }
  }

  if (skipped.length) {
    console.log(`\nSkipped ${skipped.length}:`);

    for (const entry of skipped.slice(0, 10)) {
      console.log(`  ${path.basename(entry.file)} — ${entry.reason}`);
    }
  }
}

async function walk(dir) {
  const found = [];

  for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);

    if (entry.isDirectory()) {
      found.push(...await walk(full));
    } else if (entry.name.endsWith(".md") && entry.name !== "_index.md") {
      found.push(full);
    }
  }

  return found.sort();
}

async function read(file, root) {
  const relative = path.relative(path.resolve(root), file);
  const [language, ...rest] = relative.split(path.sep);

  if (!LANGUAGES.has(language) || !rest.length) return null;

  const raw = await fs.readFile(file, "utf8");
  const match = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);

  if (!match) throw new Error("no frontmatter");

  const meta = frontmatter(match[1], file);
  const body = match[2].trim();

  if (meta.draft === true) return null;

  const slug = path.basename(file, ".md");

  /*
   * Hugo repeats the title as an H1 at the top of the body. The page template
   * renders the title itself, so carrying both would print it twice.
   */
  const cleanBody = body.replace(/^#\s+.*\r?\n+/, "").trim();

  return {
    language,
    slug,
    /* Where both exist they agree; the slug is the one every file has. */
    translationKey: String(meta.translationKey ?? slug).trim(),
    category: first(meta.categories) ?? rest[0] ?? null,
    title: String(meta.title ?? slug).trim(),
    description: String(meta.description ?? "").trim(),
    body: cleanBody,
    tags: Array.isArray(meta.tags) ? meta.tags.map(String) : [],
    publishedAt: date(meta.date)
  };
}

/*
 * Twenty files carry a `tweet:` value that YAML cannot read: the tweet wraps
 * onto a second line, so the opening quote is never closed on its own line and
 * the continuation starts with "@" — a reserved character in plain YAML.
 *
 * We do not import tweets, so rather than lose the articles the parse is
 * retried with the whole value removed, continuation lines included. Anything
 * still unparseable after that is a real problem and raises.
 */
function frontmatter(text, file) {
  try {
    return YAML.parse(text) ?? {};
  } catch (error) {
    try {
      const meta = YAML.parse(withoutTweet(text)) ?? {};

      recovered.push(path.basename(file));

      return meta;
    } catch {
      throw error;
    }
  }
}

export function withoutTweet(text) {
  const kept = [];
  let skipping = false;
  let quotes = 0;

  for (const line of text.split(/\r?\n/)) {
    if (!skipping && /^tweet:/.test(line)) {
      skipping = true;
      quotes = 0;
    }

    if (!skipping) {
      kept.push(line);
      continue;
    }

    /* Keep dropping lines until the value's quotes balance. */
    quotes += (line.match(/"/g) ?? []).length;

    if (quotes % 2 === 0) skipping = false;
  }

  return kept.join("\n");
}

const recovered = [];

const first = value => Array.isArray(value)
  ? String(value[0] ?? "").replace(/^"|"$/g, "").trim() || null
  : value
    ? String(value).replace(/^"|"$/g, "").trim()
    : null;

/*
 * Two date shapes are in the content: "2026-08-29 18:11:00-07:00" and
 * "2026-09-09T17:18:10.531317Z". Date.parse handles both; anything else keeps
 * the article rather than losing it to a bad timestamp.
 */
function date(value) {
  if (value instanceof Date) return value;

  const parsed = Date.parse(String(value ?? ""));

  return new Date(Number.isNaN(parsed) ? Date.now() : parsed);
}

async function upsert(article) {
  await pool.query(
    `INSERT INTO stories(
       language, slug, translation_key, category, tags,
       headline, standfirst, body, published_at, issue_date, origin
     )
     VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::timestamptz,$9::timestamptz::date,'import')
     ON CONFLICT (language, slug) WHERE slug IS NOT NULL
     DO UPDATE SET
       translation_key = EXCLUDED.translation_key,
       category        = EXCLUDED.category,
       tags            = EXCLUDED.tags,
       headline        = EXCLUDED.headline,
       standfirst      = EXCLUDED.standfirst,
       body            = EXCLUDED.body,
       published_at    = EXCLUDED.published_at,
       issue_date      = EXCLUDED.issue_date`,
    [
      article.language,
      article.slug,
      article.translationKey,
      article.category,
      article.tags,
      article.title,
      article.description,
      article.body,
      article.publishedAt
    ]
  );
}

try {
  await main();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
