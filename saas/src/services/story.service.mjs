import { aiJSON } from "./openai.service.mjs";
import { fetchTopicItems } from "./news.service.mjs";
import * as stories from "../models/story.model.mjs";
import { env } from "../config/env.mjs";
import { fetchArticle } from "./extract.service.mjs";
import { VERBATIM_LIMIT, longestSharedRun } from "../utils/overlap.mjs";

/*
 * The daily story pipeline.
 *
 * Three articles a topic, read and then written up in our own words.
 *
 * The source article is fetched (obeying robots.txt), used to write from, and
 * dropped — no copy of anyone's reporting is stored. Every story credits and
 * links the publisher, and the output is checked against the source for
 * verbatim overlap before it is kept, so "rewritten" is measured rather than
 * assumed. A story that cannot be fetched, or whose rewrite comes back too
 * close to the original, falls back to a headline-only write-up.
 */

export const STORIES_PER_ISSUE = 3;

/*
 * Every host that serves our own published stories: APP_ORIGIN, plus any
 * custom domains configured for enterprise customers. A story we published at
 * news.customer.com is still ours.
 */
const OWN_HOSTS = new Set(
  [env.appOrigin, ...env.ownHosts]
    .map(normaliseHost)
    .filter(Boolean)
);

function normaliseHost(value) {
  const raw = String(value ?? "").trim();

  if (!raw) return null;

  try {
    const url = raw.includes("://") ? new URL(raw) : new URL(`https://${raw}`);

    return url.host.toLowerCase().replace(/^www\./, "");
  } catch {
    return null;
  }
}

/*
 * Never rewrite our own writing.
 *
 * Hosted stories are public, indexable pages, and a public page ends up in
 * aggregators and feeds. If one came back round as a candidate we would be
 * rewriting a rewrite — drifting further from the reporting with every pass,
 * and citing ourselves as the source of it.
 *
 * Matched on host, not on the publisher name the feed supplies: that name is
 * arbitrary text a feed can put anything in, while the host is the only part
 * that actually identifies who published a page. Subdomains count, so a story
 * on news.rnews1.com is caught by rnews1.com.
 */
function isOurOwn(url) {
  const host = normaliseHost(url);

  if (!host) return false;

  for (const own of OWN_HOSTS) {
    if (host === own || host.endsWith(`.${own}`)) return true;
  }

  return false;
}

export { isOurOwn };

export async function buildIssue({ topicKey, query, language, issueDate }) {
  const existing = await stories.forIssue(topicKey, issueDate);

  if (existing.length >= STORIES_PER_ISSUE) return existing;

  const candidates = await fetchTopicItems({ query, language, summarise: false });

  /*
   * De-duplication within this topic. An article this topic has already
   * covered is skipped, which is what stops the same story resurfacing for
   * weeks. Another customer having covered it is irrelevant — they are a
   * different audience and got their own rewrite.
   */
  const original = candidates.filter(item => !isOurOwn(item.url));

  const marks = original.map(item => stories.fingerprint(item.url));
  const taken = await stories.alreadyUsed(topicKey, marks);

  const fresh = original
    .map((item, index) => ({ ...item, mark: marks[index] }))
    .filter(item => !taken.has(item.mark))
    .slice(0, STORIES_PER_ISSUE - existing.length);

  if (!fresh.length) return existing;

  const written = await rewrite(fresh, language);
  const saved = [...existing];

  for (const story of written) {
    const row = await stories.create({
      topicKey,
      issueDate,
      sourceUrl: story.url,
      sourceName: story.source,
      sourceTitle: story.title,
      publishedAt: story.published,
      headline: story.headline,
      standfirst: story.standfirst,
      body: story.body,
      fingerprint: story.mark,
      resolvedUrl: story.resolvedUrl ?? null,
      extraction: story.extraction ?? "headline_only",
      sourceChars: story.sourceChars ?? 0,
      verbatimRun: story.verbatimRun ?? 0
    });

    /* null means this topic already has that article. */
    if (row) saved.push(row);
  }

  return saved;
}

const LANGUAGES = {
  en: "English",
  es: "Spanish",
  fr: "French",
  de: "German"
};

/*
 * Reads each article, then writes it up. Sequential rather than parallel: three
 * requests a topic is not worth hammering a publisher's origin for, and being
 * unhurried is part of not becoming a nuisance.
 */
async function rewrite(items, language) {
  const read = [];

  for (const item of items) {
    const article = await fetchArticle(item.url);

    /*
     * The candidate URL was checked before we got here, but a link can redirect
     * anywhere — including back to us, through an aggregator that picked up our
     * feed. The resolved URL is the one that says who actually published this,
     * so it is checked too, and a story that turns out to be ours is dropped
     * rather than written from its headline: a headline-only write-up of our
     * own story is still a rewrite of a rewrite.
     */
    if (article?.url && isOurOwn(article.url)) {
      console.warn(
        `Skipping our own story, reached via redirect: ${article.url}`
      );

      continue;
    }

    read.push({
      ...item,
      resolvedUrl: article?.url ?? null,
      sourceText: article?.text ?? null,
      extraction: article?.text
        ? article.method
        : article?.method ?? "headline_only",
      sourceChars: article?.chars ?? 0
    });
  }

  const written = await write(read, language);

  return written.map(story => {
    if (!story.sourceText) return dropSource(story);

    /*
     * The check that makes "rewritten" a fact rather than an intention. A
     * rewrite that shares a long run with the source is not kept, however good
     * it reads — that run is the publisher's expression, not ours.
     */
    const run = longestSharedRun(
      story.sourceText,
      `${story.headline} ${story.standfirst} ${story.body}`,
      VERBATIM_LIMIT * 2
    );

    /* Prose only: figures are shared facts, which are not copyrightable. */
    if (run.prose >= VERBATIM_LIMIT) {
      console.warn(
        `Rewrite too close to source (${run.prose} prose words), ` +
        `falling back to headline: ${JSON.stringify(run.phrase.slice(0, 60))}`
      );

      return dropSource({
        ...story,
        headline: story.title,
        standfirst: `Reported by ${story.source}.`,
        body: fallbackBody(story),
        extraction: "rejected_verbatim",
        verbatimRun: run.prose
      });
    }

    return dropSource({ ...story, verbatimRun: run.prose });
  });
}

/* The publisher's text leaves the process here and is never persisted. */
function dropSource({ sourceText, ...story }) {
  return story;
}

const LENGTHS = {
  headline: 200,
  standfirst: 400,
  body: 4000
};

async function write(items, language) {
  const languageName = LANGUAGES[language] ?? LANGUAGES.en;

  const anyText = items.some(item => item.sourceText);

  const instruction = [
    "You write short original news items for a business newsletter.",
    `Write in ${languageName}.`,
    "",
    "For each article produce:",
    "- headline: your own wording, under 90 characters, no clickbait.",
    "- standfirst: one sentence, under 30 words, saying what this is about.",
    "- body: two or three short paragraphs, 110-180 words, covering what",
    "  happened and why it matters to a business reader in this market.",
    "",
    anyText
      ? [
        "You are given the publisher's article. Report the facts in it; do not",
        "reproduce its language.",
        "",
        "Rules:",
        "- Write every sentence from scratch. Never reuse the source's phrasing,",
        "  sentence structure, or opening. If a sentence of yours could be found",
        "  in the original, rewrite it.",
        "- Never copy a passage. Quote at most one short phrase, in quotation",
        "  marks, and only when the exact words are the point.",
        "- Use only facts present in the article. Do not add background you were",
        "  not given, and never invent figures, dates, names or quotes.",
        "- Do not reproduce the article's structure paragraph by paragraph.",
        "- Attribute the reporting to the publisher named.",
        "- Where an article is truncated or partial, write only what it supports."
      ].join("\n")
      : [
        "For any article with no text supplied you have only a headline and a",
        "publisher. You have NOT read it. Write only what can responsibly be",
        "said from that: never state details absent from the headline as fact,",
        "and never claim to have read the article or spoken to anyone."
      ].join("\n"),
    "",
    'Return {"stories":[{"id":"...","headline":"...","standfirst":"...","body":"..."}]}',
    "covering every id you were given."
  ].join("\n");

  try {
    const output = await aiJSON(instruction, {
      articles: items.map(item => ({
        id: item.id,
        headline: item.title,
        publisher: item.source,
        article: item.sourceText ?? null
      }))
    });

    const byId = new Map(
      (Array.isArray(output?.stories) ? output.stories : [])
        .map(entry => [String(entry.id), entry])
    );

    return items.map(item => {
      const result = byId.get(item.id);

      return {
        ...item,
        headline: text(result?.headline, item.title, LENGTHS.headline),
        standfirst: text(result?.standfirst, item.title, LENGTHS.standfirst),
        body: text(result?.body, fallbackBody(item), LENGTHS.body)
      };
    });
  } catch (error) {
    /*
     * A failed write degrades to the headline and an attribution line rather
     * than dropping the issue. A thin newsletter beats no newsletter.
     */
    console.warn(`Story rewrite failed, using headlines: ${error.message}`);

    return items.map(item => ({
      ...item,
      headline: item.title,
      standfirst: `Reported by ${item.source}.`,
      body: fallbackBody(item),
      sourceText: null,
      extraction: "headline_only"
    }));
  }
}

const fallbackBody = item =>
  `${item.title} — reported by ${item.source}. ` +
  "Follow the link for the original coverage.";

function text(value, fallback, max) {
  const cleaned = typeof value === "string" ? value.trim() : "";

  return (cleaned || fallback).slice(0, max);
}

/*
 * Which story leads this reader's issue.
 *
 * The model only ever chooses an ordering of the three stories that were
 * already written for the topic — it cannot introduce a story, and a malformed
 * answer falls back to the default order. Cached per contact per day.
 */
export async function pickForContact({ contact, topicKey, issueDate, pool: dayStories }) {
  const cached = await stories.findPicks(contact.id, topicKey, issueDate);

  if (cached) {
    const byId = new Map(dayStories.map(story => [story.id, story]));
    const ordered = cached.story_ids.map(id => byId.get(id)).filter(Boolean);

    /* Only trust the cache if it still describes today's stories. */
    if (ordered.length === dayStories.length) return ordered;
  }

  const ordering = await chooseOrder(contact, dayStories);

  await stories.savePicks({
    contactId: contact.id,
    topicKey,
    issueDate,
    storyIds: ordering.stories.map(story => story.id),
    reason: ordering.reason,
    personalised: ordering.personalised
  });

  return ordering.stories;
}

async function chooseOrder(contact, dayStories) {
  const unpersonalised = {
    stories: dayStories,
    reason: null,
    personalised: false
  };

  /*
   * With nothing known about the reader there is nothing to personalise on,
   * and a model call would be guesswork billed by the token.
   */
  if (!contact.title && !contact.company && !contact.industry) {
    return unpersonalised;
  }

  if (dayStories.length < 2) return unpersonalised;

  const instruction = [
    "You choose which story leads one reader's newsletter.",
    "You are given a reader's professional details and today's stories.",
    "Pick the story most useful to that person in their working week, then",
    "order the rest by how relevant they are to the same person.",
    "Judge only on professional relevance to their role, employer and market.",
    'Return {"order":["<id>","<id>","<id>"],"reason":"<12 words or fewer>"}',
    "using every id exactly once."
  ].join("\n");

  try {
    const output = await aiJSON(instruction, {
      reader: {
        title: contact.title ?? null,
        company: contact.company ?? null,
        industry: contact.industry ?? null
      },
      stories: dayStories.map(story => ({
        id: story.id,
        headline: story.headline,
        standfirst: story.standfirst
      }))
    });

    const byId = new Map(dayStories.map(story => [story.id, story]));

    const ordered = (Array.isArray(output?.order) ? output.order : [])
      .map(id => byId.get(String(id)))
      .filter(Boolean);

    const seen = new Set(ordered.map(story => story.id));

    /* Anything the model dropped is appended, so nobody loses a story. */
    for (const story of dayStories) {
      if (!seen.has(story.id)) ordered.push(story);
    }

    if (ordered.length !== dayStories.length) return unpersonalised;

    return {
      stories: ordered,
      reason: typeof output?.reason === "string"
        ? output.reason.trim().slice(0, 120)
        : null,
      personalised: true
    };
  } catch (error) {
    console.warn(`Personalisation failed for a reader: ${error.message}`);
    return unpersonalised;
  }
}
