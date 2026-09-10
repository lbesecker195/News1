import path from "node:path";

import ejs from "ejs";

import { ROOT } from "../config/env.mjs";
import { brandContent, fill, reportContent } from "../config/content.mjs";

import * as briefs from "../models/brief.model.mjs";

import { pathFor } from "../controllers/editorial.controller.mjs";
import { APP, safeURL } from "./platform.service.mjs";
import { firstSentence } from "../utils/teaser.mjs";
import { directionOf } from "../utils/languages.mjs";
import { REQUIRED_STAKEHOLDERS } from "../models/subscriber.model.mjs";

/*
 * The brief as a landing page.
 *
 * One rendering path serves the page at /brief/:id and feeds the PDF, so what
 * a reader prints is exactly what they saw. The page is built from the day's
 * stories and content.json, never from the emailed HTML.
 *
 * Every story is a link to its hosted page — an archive article at its
 * /{lang}/{topic}/{slug}/{date} URL, a crawled story at /news/:token/:id — so a
 * click lands on our own reporting rather than leaving the site. Only when
 * there is no hosted page does the link fall back to the publisher.
 */

const VIEW = path.join(ROOT, "src", "views", "report.ejs");

export async function renderBriefPage(record) {
  const content = reportContent();
  const model = await presentBrief(record, content);

  const html = await ejs.renderFile(VIEW, model, {
    cache: process.env.NODE_ENV === "production"
  });

  return { html, content, model };
}

export async function presentBrief(record, content = reportContent()) {
  const issue = await briefs.storiesFor(record);

  const meta = record.meta ?? {};
  const reader = meta.reader ?? null;
  const sections = Array.isArray(meta.sections) ? meta.sections : [];
  const keywords = Array.isArray(record.keywords) ? record.keywords : [];
  const language = meta.language ?? "en";

  /* "Because …" — the reason a section was chosen for this reader. */
  const whyFor = new Map(sections.map(section => [
    String(section.name).toLowerCase(),
    section.why
  ]));

  const values = {
    company: reader?.company ?? record.company ?? "Your company",
    date: record.date_slug ?? "",
    count: String(issue.length),
    reader: reader?.name ?? "",
    title: reader?.title ?? ""
  };

  const block = content.blocks.find(entry => entry.type === "stories") ?? {};
  const shown = issue
    .slice(0, block.limit ?? 8)
    .map(story => presentStory(story, { record, whyFor }));

  const hero = block.hero !== false ? shown[0] ?? null : null;

  return {
    content,
    brand: brandContent(),
    lang: language,
    dir: directionOf(language),
    title: `${fill(content.title, values)} — ${values.company}`,
    eyebrow: fill(content.eyebrow, values),
    date: values.date,
    dateLong: longDate(values.date, language),
    preparedFor: reader
      ? [reader.name, reader.title, reader.company].filter(Boolean).join(", ")
      : record.company ?? null,
    reader,
    sections,
    topics: reader
      ? sections.map(section => section.name).join(", ")
      : [record.industry, ...keywords].filter(Boolean).join(", "),
    stories: shown,
    hero,
    items: hero ? shown.slice(1) : shown,
    count: issue.length,
    columns: block.columns ?? 2,
    siteUrl: APP,
    pageUrl: `${APP}/brief/${record.id}`,
    generatedAt: new Date().toISOString().slice(0, 10)
  };
}

function presentStory(story, { record, whyFor }) {
  const section = story.category ?? null;

  return {
    id: story.id,
    headline: story.headline,
    standfirst: story.standfirst ?? "",
    teaser: firstSentence(story.standfirst),
    /* The section for archive stories; the publisher for crawled ones. */
    kicker: section ?? story.source_name ?? "",
    why: section ? whyFor.get(section.toLowerCase()) ?? null : null,
    source: story.source_name ?? null,
    url: hostedUrl(story, record)
  };
}

function hostedUrl(story, record) {
  if (story.slug && story.language && story.date_slug) {
    return `${APP}/${pathFor(story)}`;
  }

  /*
   * A crawled story has a hosted page only once the tenant's feed is
   * published; before that the link would 409, so it goes to the publisher.
   */
  if (story.topic_key && record.public_token &&
      (record.stakeholder_count ?? 0) >= REQUIRED_STAKEHOLDERS) {
    return `${APP}/news/${record.public_token}/${story.id}`;
  }

  return safeURL(story.source_url) ?? null;
}

/*
 * "Thursday, September 10, 2026", in the report's language. Anchored to noon
 * UTC so no timezone can move a date slug onto the neighbouring day.
 */
function longDate(slug, language) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(slug)) return slug;

  try {
    return new Intl.DateTimeFormat(language, {
      weekday: "long",
      month: "long",
      day: "numeric",
      year: "numeric",
      timeZone: "UTC"
    }).format(new Date(`${slug}T12:00:00Z`));
  } catch {
    return slug;
  }
}
