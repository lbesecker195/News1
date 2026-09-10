import fs from "node:fs";
import path from "node:path";

import { z } from "zod";

import { ROOT } from "./env.mjs";

/*
 * Copy and layout for the daily report, from content.json.
 *
 * The point is that a new report variant is a config change, not a new
 * template: the page is assembled from an ordered list of blocks, and the
 * words around them live in the file rather than in the markup.
 *
 * Everything is optional. A missing, malformed or half-written content.json
 * falls back to the defaults below rather than failing the page — a report a
 * customer is waiting for should not 500 over a stray comma.
 */

/*
 * Colours reach a <style> block, so they are validated as colours. Anything
 * else here would be arbitrary CSS injected through a config file.
 */
const colour = z.string().regex(
  /^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i,
  "must be a hex colour like #1a4fd6"
);

const block = z.discriminatedUnion("type", [
  z.object({ type: z.literal("masthead") }),
  z.object({ type: z.literal("summary") }),
  /*
   * The stories: the first as a hero card, the rest as headlines in columns.
   * Bodies are never printed — this is a landing page, and the page each
   * headline opens is where the reading happens.
   */
  z.object({
    type: z.literal("stories"),
    limit: z.number().int().min(1).max(50).default(8),
    hero: z.boolean().default(true),
    columns: z.union([z.literal(1), z.literal(2)]).default(2)
  }),
  z.object({
    type: z.literal("note"),
    title: z.string().max(120).default(""),
    body: z.string().max(2000)
  }),
  /*
   * Only rendered when a report was built for a named reader; on a company's
   * daily brief there is no ranking to show, and the block is skipped.
   */
  z.object({ type: z.literal("impact") }),
  z.object({ type: z.literal("footer") })
]);

const schema = z.object({
  title: z.string().max(120).default("Daily Briefing"),
  eyebrow: z.string().max(160).default("{{company}}"),
  footnote: z.string().max(600).default(""),
  labels: z.object({
    reportedBy: z.string().max(60).default("Reported by"),
    readStory: z.string().max(60).default("Read the full story"),
    alsoToday: z.string().max(60).default("Also today"),
    storiesToday: z.string().max(60).default("stories today"),
    preparedFor: z.string().max(60).default("Prepared for"),
    topics: z.string().max(60).default("Following"),
    whyThese: z.string().max(60).default("Why these sections")
  }).default({}),
  theme: z.object({
    accent: colour.default("#1a4fd6"),
    ink: colour.default("#14181f"),
    muted: colour.default("#5a6472"),
    paper: colour.default("#ffffff")
  }).default({}),
  print: z.object({
    pageSize: z.enum(["A4", "Letter", "Legal"]).default("A4"),
    margin: z.string().regex(/^\d{1,3}(mm|cm|in|pt)$/).default("16mm")
  }).default({}),
  blocks: z.array(block).min(1).default([
    { type: "masthead" },
    { type: "stories", limit: 8, hero: true, columns: 2 },
    { type: "impact" },
    { type: "footer" }
  ])
});

/*
 * The brand, in the same file as everything else that is words rather than
 * code. The name explains itself once the tagline is next to it: real news,
 * made for one reader.
 */
const brandSchema = z.object({
  name: z.string().max(60).default("rnews1"),
  tagline: z.string().max(120).default("Real news, made for one."),
  description: z.string().max(300).default(
    "A newsletter written for one reader at a time. Real reporting, chosen " +
    "and written for the person opening it. $25/month."
  )
}).default({});

/*
 * The archive's own copy. The index used to be headed "Journal", which named
 * the format rather than the thing that makes it worth reading.
 */
const archiveSchema = z.object({
  title: z.string().max(120).default("Real News, Made for One"),
  intro: z.string().max(400).default(
    "Every story here is written for one reader at a time."
  ),
  sectionIntro: z.string().max(400).default(
    "{{section}} reporting, written for the person reading it."
  )
}).default({});

export const CONTENT_FILE = path.join(ROOT, "content.json");

let cached = null;
let cachedBrand = null;
let cachedArchive = null;
let readAt = 0;

/*
 * Re-read when the file changes, so editing copy is a save rather than a
 * restart. In production the mtime check is one stat per request, which is
 * cheaper than the render it precedes.
 */
export function reportContent() {
  let stamp = 0;

  try {
    stamp = fs.statSync(CONTENT_FILE).mtimeMs;
  } catch {
    /* No file at all is fine: the defaults are a complete report. */
  }

  if (cached && stamp === readAt) return cached;

  read(stamp);

  return cached;
}

export function archiveContent() {
  let stamp = 0;

  try {
    stamp = fs.statSync(CONTENT_FILE).mtimeMs;
  } catch {
    /* Defaults are complete. */
  }

  if (cachedArchive && stamp === readAt) return cachedArchive;

  read(stamp);

  return cachedArchive;
}

export function brandContent() {
  let stamp = 0;

  try {
    stamp = fs.statSync(CONTENT_FILE).mtimeMs;
  } catch {
    /* Defaults are a complete brand. */
  }

  if (cachedBrand && stamp === readAt) return cachedBrand;

  read(stamp);

  return cachedBrand;
}

function read(stamp) {
  const raw = json();

  cached = parse(schema, raw?.report, "report");
  cachedBrand = parse(brandSchema, raw?.brand, "brand");
  cachedArchive = parse(archiveSchema, raw?.archive, "archive");
  readAt = stamp;
}

function parse(shape, value, name) {
  const result = shape.safeParse(value ?? {});

  if (result.success) return result.data;

  const first = result.error.issues[0];

  console.error(
    `content.json is invalid at "${name}.${first.path.join(".")}": ` +
    `${first.message}. Using defaults.`
  );

  return shape.parse({});
}

function json() {
  try {
    return JSON.parse(fs.readFileSync(CONTENT_FILE, "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") {
      console.error(
        `content.json is not valid JSON, using defaults: ${error.message}`
      );
    }

    return {};
  }
}

/*
 * {{company}} and friends. Values are substituted as plain text and the
 * template escapes the result, so a placeholder cannot introduce markup.
 */
export function fill(template, values) {
  return String(template ?? "").replace(
    /\{\{(\w+)\}\}/g,
    (match, key) => (key in values ? String(values[key]) : match)
  );
}

/* Only for tests: drops the cache so a rewritten file is picked up at once. */
export function resetContentCache() {
  cached = null;
  cachedBrand = null;
  cachedArchive = null;
  readAt = 0;
}
