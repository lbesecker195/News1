import fs from "node:fs";

import * as companies from "../models/company.model.mjs";
import * as briefs from "../models/brief.model.mjs";
import * as stories from "../models/story.model.mjs";

import {
  APP,
  safeURL,
  briefPdfPath,
  writeBriefPdf
} from "../services/platform.service.mjs";

import { renderBriefPage } from "../services/brief-page.service.mjs";

import { HttpError } from "../utils/http-error.mjs";
import { isUUID } from "../utils/validation.mjs";
import { REQUIRED_STAKEHOLDERS } from "../models/subscriber.model.mjs";

const FEED_ITEMS = 8;

/*
 * Publishing is what the stakeholder roster gates. A tenant can pay and receive
 * their briefing straight away; the feed, the embed and the hosted articles go
 * live once ten stakeholders from the company are on board.
 *
 * An incomplete roster answers 409 rather than 404 on purpose: the person most
 * likely to open an unpublished feed URL is the owner testing it, and telling
 * them why is worth more than hiding a token they already hold.
 */
async function requirePublicTenant(token) {
  if (!isUUID(token)) {
    throw new HttpError(404, "Feed not found.");
  }

  const tenant = await companies.findPublicTenant(token);

  if (!tenant) {
    throw new HttpError(404, "Feed not found.");
  }

  if (tenant.stakeholder_count < REQUIRED_STAKEHOLDERS) {
    throw new HttpError(
      409,
      `This feed is not published yet. It goes live once ${
        REQUIRED_STAKEHOLDERS
      } stakeholders have been added in the dashboard.`
    );
  }

  return tenant;
}

/*
 * A stored story, shaped for the views. The public surfaces read the `stories`
 * table — the same rows the newsletter is built from — so a story a reader
 * saw in their inbox resolves at its hosted URL rather than 404ing.
 */
function presentStory(tenant, story) {
  return {
    id: story.id,
    title: story.headline,
    summary: story.standfirst,
    body: story.body,
    source: story.source_name,
    published: story.published_at,
    sourceUrl: safeURL(story.source_url),
    hostedUrl: `${APP}/news/${tenant.public_token}/${story.id}`
  };
}

export async function rss(req, res) {
  const tenant = await requirePublicTenant(req.params.token);

  const items = (await stories.recentForTopic(tenant.topic_key, FEED_ITEMS))
    .map(story => ({
      ...presentStory(tenant, story),
      pubDate: pubDate(story.published_at)
    }));

  res.type("application/rss+xml")
    .set("Cache-Control", "public, max-age=300")
    .render("feeds/rss", {
      tenant,
      items,
      lastBuildDate: pubDate(tenant.refreshed_at ?? Date.now())
    });
}

/* An unparseable date must not become "Invalid Date" in a published feed. */
function pubDate(value) {
  const parsed = new Date(value);

  return (
    Number.isNaN(parsed.getTime()) ? new Date() : parsed
  ).toUTCString();
}

export async function embed(req, res) {
  const tenant = await requirePublicTenant(req.params.token);

  /*
   * The embed is the one page meant to be framed by customers, so helmet's
   * frame-ancestors 'self' and X-Frame-Options are replaced here rather than
   * loosened application-wide.
   */
  res.removeHeader("X-Frame-Options");
  res.set(
    "Content-Security-Policy",
    "default-src 'none'; style-src 'self'; img-src 'self' data:; " +
    "frame-ancestors *; base-uri 'none'; form-action 'none'"
  );
  res.set("Cache-Control", "public, max-age=300");

  res.render("feeds/embed", {
    title: `${tenant.name} news`,
    /* Framed inside the customer's own page: no Rnews1 navigation. */
    chrome: false,
    tenant,
    items: (await stories.recentForTopic(tenant.topic_key, FEED_ITEMS))
      .map(story => presentStory(tenant, story))
  });
}

export async function article(req, res) {
  const tenant = await requirePublicTenant(req.params.token);

  if (!isUUID(req.params.id)) {
    throw new HttpError(404, "Article not found.");
  }

  const story = await stories.findById(req.params.id);

  /*
   * The story has to belong to this tenant's topic. Without that check a
   * public token would expose every story on the platform, not just the ones
   * this customer publishes.
   */
  if (!story || story.topic_key !== tenant.topic_key) {
    throw new HttpError(404, "Article not found.");
  }

  res.set("Cache-Control", "public, max-age=300").render("feeds/article", {
    title: story.headline,
    /*
     * The one page meant to be found by search. Everything else on the site is
     * noindex by default; this is the topical-authority surface, so it says so.
     */
    indexable: true,
    tenant,
    item: presentStory(tenant, story)
  });
}

/*
 * The briefing as a landing page, rendered by the same function that feeds
 * the PDF so the two never drift. See brief-page.service.mjs.
 */
export async function brief(req, res) {
  const record = await requireBrief(req.params.id);
  const { html } = await renderBriefPage(record);

  res.set("Cache-Control", "private, no-store").type("html").send(html);
}

/*
 * The issue as it was mailed. Kept because the stored HTML is the record of
 * what a recipient actually received, which the report page — rendered fresh
 * from data and current config — is not.
 */
export async function briefEmail(req, res) {
  const record = await requireBrief(req.params.id);

  res.set("Cache-Control", "private, no-store")
    .type("html")
    .send(record.html);
}

/*
 * The PDF is made on first request if the worker has not already written it,
 * so a report built by hand — the custom-report script, say — prints too.
 */
export async function pdf(req, res) {
  const record = await requireBrief(req.params.id);
  const file = briefPdfPath(record.id);

  if (!record.has_pdf || !fs.existsSync(file)) {
    const { html, content } = await renderBriefPage(record);

    await writeBriefPdf(record.id, html, content.print);
    await briefs.markPdfWritten(record.id);
  }

  res.set("Cache-Control", "private, no-store");
  res.download(file, `briefing-${record.date_slug ?? record.id}.pdf`);
}

async function requireBrief(id) {
  if (!isUUID(id)) {
    throw new HttpError(404, "Brief not found.");
  }

  const record = await briefs.findUnexpired(id);

  if (!record) {
    throw new HttpError(404, "Brief not found.");
  }

  return record;
}
