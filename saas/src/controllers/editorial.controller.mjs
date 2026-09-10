import * as stories from "../models/story.model.mjs";

import { APP } from "../services/platform.service.mjs";
import { HttpError } from "../utils/http-error.mjs";
import { renderMarkdown } from "../utils/markdown.mjs";
import { archiveContent, fill } from "../config/content.mjs";
import { readingMinutes } from "../utils/reading-time.mjs";
import { directionOf, languageName } from "../utils/languages.mjs";

/*
 * The imported archive, served at /{language}/{topic}/{slug}/{yyyy-mm-dd}.
 *
 * The Hugo site published these without the date segment, so the undated path
 * still resolves and redirects here permanently — existing links and whatever
 * ranking they carry survive the move to a hosted domain, which was the point
 * of importing rather than republishing.
 *
 * Locales are separate pages throughout. Every translation shares a slug and a
 * date, so the URLs differ only in the language segment, and each page
 * declares its siblings with hreflang: twelve translations of one article
 * rather than twelve competing duplicates.
 */

const PAGE_SIZE = 24;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

/*
 * Formatted by Postgres, never derived from a JS Date. An article dated
 * 2026-08-29 18:11-07:00 is 2026-08-30 in UTC, and toISOString() would put it
 * in the URL under the wrong day.
 */
export const dateOf = story => story.date_slug;

/* /{language}/{topic}/{slug}/{yyyy-mm-dd} */
export function pathFor(story) {
  return [
    story.language,
    encodeURIComponent(String(story.category ?? "news").toLowerCase()),
    encodeURIComponent(story.slug),
    dateOf(story)
  ].join("/");
}

const alternates = translations => translations.map(row => ({
  language: row.language,
  /* The endonym: a reader scanning for their language recognises it. */
  name: languageName(row.language),
  dir: directionOf(row.language),
  url: `${APP}/${pathFor(row)}`
}));

/* Listing rows carry a body length rather than the body itself. */
const minutesFromLength = length =>
  Math.max(1, Math.round((Number(length) || 0) / 5 / 220));

const forCard = row => ({
  ...row,
  href: `/${pathFor(row)}`,
  minutes: minutesFromLength(row.body_length)
});

/* The listing pages stop at the topic; only articles carry a date. */
const slugPath = row =>
  `${encodeURIComponent(String(row.category ?? "news").toLowerCase())}/${
    encodeURIComponent(row.slug)
  }/${dateOf(row)}`;

export async function article(req, res) {
  const { language, topic, slug, date } = req.params;

  if (!stories.isLanguage(language)) {
    throw new HttpError(404, "Page not found.");
  }

  const story = await stories.findEditorial({ language, slug });

  if (!story) {
    throw new HttpError(404, "Article not found.");
  }

  const canonical = `${APP}/${pathFor(story)}`;

  /*
   * The language and slug identify the article; the topic and date describe
   * it. Anything that is not the canonical path — a stale topic, the wrong
   * date, or no date at all, which is every link the Hugo site published —
   * redirects here rather than 404ing. Nothing that used to resolve stops
   * resolving.
   */
  const onCanonicalPath =
    date === dateOf(story) &&
    DATE.test(String(date)) &&
    String(topic).toLowerCase() ===
      String(story.category ?? "news").toLowerCase();

  if (!onCanonicalPath) {
    return res.redirect(301, canonical);
  }

  const [translations, related] = await Promise.all([
    stories.translationsOf(story.translation_key),
    stories.relatedTo({
      language,
      category: story.category,
      excludeId: story.id,
      limit: 3
    })
  ]);

  /*
   * A thin section must not leave the foot of the article empty — that is the
   * moment the reader decides whether the session continues.
   */
  const more = related.length >= 3
    ? related
    : [
      ...related,
      ...await stories.alsoInLanguage({
        language,
        excludeIds: [story.id, ...related.map(row => row.id)],
        limit: 3 - related.length
      })
    ];

  res.set("Cache-Control", "public, max-age=600").render("editorial/article", {
    title: story.headline,
    htmlLang: language,
    dir: directionOf(language),
    bodyClass: "reading",
    indexable: true,
    story,
    date: dateOf(story),
    minutes: readingMinutes(story.body),
    html: renderMarkdown(story.body),
    canonicalUrl: canonical,
    alternates: alternates(translations),
    related: more.map(forCard),
    language
  });
}

/* Every link the Hugo site published, without the date segment. */
export async function undatedArticle(req, res) {
  return article(req, res);
}

export async function index(req, res) {
  const { language } = req.params;

  if (!stories.isLanguage(language)) {
    throw new HttpError(404, "Page not found.");
  }

  const page = Math.max(1, Number(req.query.page) || 1);

  const [items, categories] = await Promise.all([
    stories.listEditorial({
      language,
      limit: PAGE_SIZE,
      offset: (page - 1) * PAGE_SIZE
    }),
    stories.editorialCategories(language)
  ]);

  if (!items.length && page > 1) {
    throw new HttpError(404, "Page not found.");
  }

  const archive = archiveContent();

  res.set("Cache-Control", "public, max-age=600").render("editorial/index", {
    title: archive.title,
    heading: archive.title,
    intro: archive.intro,
    htmlLang: language,
    dir: directionOf(language),
    bodyClass: "reading",
    indexable: true,
    language,
    category: null,
    items: items.map(forCard),
    categories,
    page,
    more: items.length === PAGE_SIZE
  });
}

export async function topic(req, res) {
  const { language, topic: name } = req.params;

  if (!stories.isLanguage(language)) {
    throw new HttpError(404, "Page not found.");
  }

  const page = Math.max(1, Number(req.query.page) || 1);

  const [items, categories] = await Promise.all([
    stories.listEditorial({
      language,
      category: name,
      limit: PAGE_SIZE,
      offset: (page - 1) * PAGE_SIZE
    }),
    stories.editorialCategories(language)
  ]);

  if (!items.length) {
    throw new HttpError(404, "Nothing published in this section.");
  }

  const archive = archiveContent();
  const section = items[0].category ?? name;

  res.set("Cache-Control", "public, max-age=600").render("editorial/index", {
    title: section,
    heading: section,
    intro: fill(archive.sectionIntro, { section }),
    htmlLang: language,
    dir: directionOf(language),
    bodyClass: "reading",
    indexable: true,
    language,
    category: section,
    items: items.map(forCard),
    categories,
    page,
    more: items.length === PAGE_SIZE
  });
}
