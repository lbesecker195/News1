import { aiJSON } from "./openai.service.mjs";
import { fetchArticle } from "./extract.service.mjs";
import { fetchTopicItems } from "./news.service.mjs";
import { isOurOwn } from "./story.service.mjs";
import * as stories from "../models/story.model.mjs";

import { LANGUAGE_NAMES } from "../utils/languages.mjs";
import { VERBATIM_LIMIT, longestSharedRun } from "../utils/overlap.mjs";
import { mapConcurrent } from "../utils/concurrent.mjs";

/*
 * Writing the journal.
 *
 * This replaces the two scripts the Hugo site ran: a Python crawler that wrote
 * an English article per section, and a Node script that translated each one
 * into eleven more languages. Both stages happen here, against the database,
 * with the same guarantees the newsletter pipeline gives:
 *
 *   - the source article is read, written from, and dropped — never stored;
 *   - the result is measured against the source for verbatim overlap and
 *     rejected if it reads as a paraphrase rather than a rewrite;
 *   - a source the archive has already covered is never covered twice.
 *
 * Translations are separate rows sharing a slug and a translation key, which
 * is what lets each locale be its own page with its own URL and hreflang.
 */

/* The sections the archive publishes, matching the imported content. */
export const CATEGORIES = [
  "AI", "Business", "Compliance", "Cosmos", "Crypto", "Entertainment",
  "Health", "Science", "Sports", "Technology", "USA", "World"
];

/*
 * What to search for in each section. These are search queries, not the
 * section names, because "USA" and "World" are labels rather than topics.
 */
const QUERIES = {
  AI: "artificial intelligence machine learning research industry",
  Business: "business economy markets corporate earnings",
  Compliance: "regulatory compliance data breach security enforcement",
  Cosmos: "astronomy space telescope cosmology mission",
  Crypto: "cryptocurrency bitcoin blockchain digital assets",
  Entertainment: "entertainment film television music industry",
  Health: "health medicine clinical research public health",
  Science: "scientific research discovery study published",
  Sports: "sports competition league championship",
  Technology: "technology software hardware engineering industry",
  USA: "United States national news policy",
  World: "world international affairs diplomacy"
};

export const SOURCE_LANGUAGE = "en";

/*
 * Translations of one article are independent of each other, so they run a few
 * at a time rather than in series — the difference between eight minutes an
 * article and under two. Bounded because the alternative is meeting the
 * account's rate limit, whose backoff would undo the gain.
 */
export const TRANSLATION_CONCURRENCY = 4;

export const TRANSLATION_LANGUAGES = Object.keys(LANGUAGE_NAMES)
  .filter(code => code !== SOURCE_LANGUAGE);

/*
 * Writes one article for one section, in every language asked for.
 *
 * Returns a report rather than throwing: a section with no fresh coverage, or
 * a source that cannot be read, is an ordinary outcome and must not stop the
 * other eleven sections.
 */
export async function writeForCategory({
  category,
  languages = TRANSLATION_LANGUAGES,
  concurrency = TRANSLATION_CONCURRENCY,
  dryRun = false,
  now = new Date()
} = {}) {
  const query = QUERIES[category];

  if (!query) {
    return { category, status: "unknown_category" };
  }

  const candidates = await findCandidates(query);

  if (!candidates.length) {
    return { category, status: "nothing_fresh" };
  }

  /*
   * Work through the candidates until one both reads and rewrites cleanly.
   *
   * Two things send us on to the next publisher: a source that cannot be read
   * (paywalled, script-rendered, blocked), and a rewrite that comes back too
   * close to its source. Giving up at either left whole sections empty for the
   * day when the next story along would have worked — Crypto failed twice on
   * the same earnings report, whose figures the model kept arranging the same
   * way, while five other candidates sat unread.
   */
  let candidate = null;
  let article = null;
  let written = null;
  let run = null;
  const attempts = [];

  for (const next of candidates.slice(0, MAX_ATTEMPTS)) {
    const fetched = await fetchArticle(next.url);

    if (!fetched?.text) {
      attempts.push({
        source: next.source,
        outcome: fetched?.method ?? "fetch failed"
      });

      continue;
    }

    const draft = await writeArticle({
      category,
      headline: next.title,
      publisher: next.source,
      source: fetched.text
    });

    if (!draft) {
      attempts.push({ source: next.source, outcome: "write failed" });
      continue;
    }

    /*
     * The same check the newsletter applies, measured on prose so a run padded
     * out by figures is shared fact rather than shared style. A draft that
     * shares a long run with its source is a paraphrase wearing a rewrite's
     * clothes, and it is not published — there is no headline-only fallback,
     * because a journal piece written from a headline alone would be worth
     * nothing.
     */
    const overlap = longestSharedRun(
      fetched.text,
      `${draft.headline} ${draft.standfirst} ${draft.body}`,
      VERBATIM_LIMIT * 2
    );

    if (overlap.prose >= VERBATIM_LIMIT) {
      attempts.push({
        source: next.source,
        outcome: `too close (${overlap.prose} words: "${overlap.phrase.slice(0, 40)}…")`
      });

      continue;
    }

    candidate = next;
    article = fetched;
    written = draft;
    run = overlap;
    break;
  }

  if (!written) {
    const allUnreadable = attempts.every(a => !a.outcome.startsWith("too close"));

    return {
      category,
      status: allUnreadable ? "unreadable" : "too_close_to_source",
      detail: attempts.map(a => `${a.source}: ${a.outcome}`).join("; "),
      attempts: attempts.length
    };
  }

  const slug = await uniqueSlug(written.headline, category);

  const rows = [{
    language: SOURCE_LANGUAGE,
    ...written,
    /* Only the source-language row carries the fingerprint. */
    fingerprint: candidate.mark,
    sourceUrl: article.url ?? candidate.url,
    sourceName: candidate.source
  }];

  const translations = await mapConcurrent(
    languages,
    concurrency,
    async language => {
      const translated = await translateArticle({
        article: written,
        language,
        category
      });

      return translated ? { language, ...translated } : null;
    }
  );

  /* Order is preserved, so the languages come back as they were asked for. */
  rows.push(...translations.filter(Boolean));

  if (dryRun) {
    return {
      category,
      status: "would_publish",
      slug,
      headline: written.headline,
      languages: rows.map(row => row.language),
      verbatimRun: run.prose,
      sourceChars: article.chars
    };
  }

  const published = [];

  for (const row of rows) {
    const saved = await stories.createEditorial({
      language: row.language,
      slug,
      translationKey: slug,
      category,
      tags: written.tags,
      headline: row.headline,
      standfirst: row.standfirst,
      body: row.body,
      publishedAt: now,
      issueDate: issueDate(now),
      fingerprint: row.fingerprint ?? null,
      sourceUrl: row.sourceUrl ?? null,
      sourceName: row.sourceName ?? null,
      verbatimRun: run.prose
    });

    if (saved) published.push(row.language);
  }

  return {
    category,
    status: "published",
    slug,
    headline: written.headline,
    languages: published,
    verbatimRun: run.prose,
    sourceChars: article.chars
  };
}

/*
 * The URL date for something published now. UTC, so a run at either side of
 * midnight files every language of an article under the same day.
 */
const issueDate = at => at.toISOString().slice(0, 10);

/* How many publishers to try before giving the section up for the day. */
const MAX_ATTEMPTS = 5;

/*
 * Stories in this section the archive has not already covered, most recent
 * first. Fingerprints are checked in one query rather than per candidate.
 */
async function findCandidates(query) {
  const items = await fetchTopicItems({ query });

  if (!items.length) return [];

  const marks = items.map(item => stories.fingerprint(item.url));
  const covered = await stories.archiveCovers(marks);

  return items
    .map((item, index) => ({ ...item, mark: marks[index] }))
    .filter(item => !covered.has(item.mark) && !isOurOwn(item.url));
}

/* ---- writing ------------------------------------------------------------ */

const MAX = { headline: 200, standfirst: 400, body: 20_000 };

async function writeArticle({ category, headline, publisher, source }) {
  const instruction = [
    "You write original news features for a general-interest journal.",
    "",
    "You are given a publisher's article. Report the facts in it in your own",
    "words. This is a rewrite, not a summary: it should stand as its own",
    "piece of writing.",
    "",
    "Produce:",
    "- headline: your own wording, under 80 characters, plain and factual.",
    "- standfirst: one sentence under 35 words saying what the piece is about.",
    "- body: 600-900 words of Markdown. Open with the news, then give the",
    "  context a reader needs to understand why it matters. Use two or three",
    "  '##' subheadings. No H1 — the page supplies the title.",
    "- tags: 5 to 10 lowercase topic tags.",
    "",
    "Rules:",
    "- Write every sentence from scratch. Never reuse the source's phrasing or",
    "  sentence structure. If a sentence of yours could be found in the",
    "  original, rewrite it.",
    "- Quote at most one short phrase, in quotation marks, and only when the",
    "  exact words matter.",
    "- Use only facts present in the article. Never invent figures, dates,",
    "  names, quotes or events.",
    "- Attribute the reporting to the publisher named.",
    "- Do not open with the same sentence or angle as the source.",
    "",
    'Return {"headline":"...","standfirst":"...","body":"...","tags":["..."]}'
  ].join("\n");

  try {
    const output = await aiJSON(instruction, {
      section: category,
      publisher,
      sourceHeadline: headline,
      article: source
    });

    if (!output?.headline || !output?.body) return null;

    return {
      headline: String(output.headline).trim().slice(0, MAX.headline),
      standfirst: String(output.standfirst ?? "").trim().slice(0, MAX.standfirst),
      body: String(output.body).trim().slice(0, MAX.body),
      tags: Array.isArray(output.tags)
        ? output.tags.map(tag => String(tag).trim().toLowerCase()).slice(0, 10)
        : []
    };
  } catch (error) {
    console.warn(`Writing ${category} failed: ${error.message}`);
    return null;
  }
}

/*
 * A translation of our own article, not of the publisher's. Markdown structure
 * has to survive, because the same renderer serves every locale.
 */
export async function translateArticle({ article, language, category }) {
  const target = LANGUAGE_NAMES[language];

  if (!target) return null;

  const instruction = [
    `You translate journalism into ${target.english} (${target.name}).`,
    "",
    "Translate the headline, standfirst and body faithfully and idiomatically —",
    "this should read as though it were written in the target language, not as",
    "a literal rendering.",
    "",
    "Rules:",
    "- Preserve the Markdown exactly: '##' subheadings, '**' emphasis, links.",
    "- Keep every fact, name, figure and date unchanged.",
    "- Do not add, remove or summarise anything.",
    "- Transliterate personal and place names where that is the convention in",
    "  the target language; otherwise leave them as they are.",
    "",
    'Return {"headline":"...","standfirst":"...","body":"..."}'
  ].join("\n");

  try {
    const output = await aiJSON(instruction, {
      section: category,
      headline: article.headline,
      standfirst: article.standfirst,
      body: article.body
    }, {
      /*
       * One retry, not four. A missing locale is backfilled by the translator
       * later, and four rounds of exponential backoff per language turns one
       * flaky provider into minutes of a stalled run.
       */
      maxRetries: 1
    });

    if (!output?.headline || !output?.body) return null;

    return {
      headline: String(output.headline).trim().slice(0, MAX.headline),
      standfirst: String(output.standfirst ?? "").trim().slice(0, MAX.standfirst),
      body: String(output.body).trim().slice(0, MAX.body)
    };
  } catch (error) {
    /* One missing locale is better than losing the article in eleven. */
    console.warn(`Translating to ${language} failed: ${error.message}`);
    return null;
  }
}

/* ---- slugs -------------------------------------------------------------- */

export function slugify(text) {
  return String(text ?? "")
    .normalize("NFKD")
    /* Drop combining marks so "café" becomes "cafe", not "caf". */
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/['’]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 70)
    .replace(/-+$/, "");
}

/*
 * Slugs are shared across a translation set and appear in the URL, so they
 * have to be unique across the whole archive. A collision takes a suffix
 * rather than overwriting somebody else's article.
 */
async function uniqueSlug(headline, category) {
  const base = slugify(headline) || slugify(category) || "story";

  if (!await stories.slugTaken(base)) return base;

  for (let n = 2; n <= 20; n++) {
    const candidate = `${base}-${n}`;

    if (!await stories.slugTaken(candidate)) return candidate;
  }

  return `${base}-${Date.now().toString(36)}`;
}

/* ---- backfilling missing locales ---------------------------------------- */

/*
 * Fills the gaps in the archive.
 *
 * Two things leave a translation group short of twelve languages: the Hugo
 * import brought over 29 groups that were only ever published in eight or ten,
 * and a translation that fails while writing leaves the article live in the
 * languages that succeeded. Both are the same problem, and this is the fix for
 * both — it is safe to run repeatedly, and does nothing when nothing is
 * missing.
 */
export async function backfillTranslations({
  languages = Object.keys(LANGUAGE_NAMES),
  limit = 25,
  concurrency = TRANSLATION_CONCURRENCY,
  dryRun = false
} = {}) {
  const groups = await stories.missingTranslations({ languages, limit });
  const results = [];

  for (const group of groups) {
    const source = await stories.sourceFor(group.translation_key, SOURCE_LANGUAGE);

    if (!source) {
      results.push({
        key: group.translation_key,
        status: "no_source",
        missing: group.missing
      });

      continue;
    }

    if (dryRun) {
      results.push({
        key: group.translation_key,
        status: "would_translate",
        from: source.language,
        missing: group.missing
      });

      continue;
    }

    const added = [];
    const failed = [];

    for (const language of group.missing) {
      const translated = await translateArticle({
        article: {
          headline: source.headline,
          standfirst: source.standfirst,
          body: source.body
        },
        language,
        category: source.category
      });

      if (!translated) {
        failed.push(language);
        continue;
      }

      const saved = await stories.createEditorial({
        language,
        slug: source.slug,
        translationKey: group.translation_key,
        category: source.category,
        tags: source.tags ?? [],
        headline: translated.headline,
        standfirst: translated.standfirst,
        body: translated.body,
        publishedAt: source.published_at,
        /* The sibling's date, verbatim — never recomputed. */
        issueDate: source.date_slug,
        /* A translation is the same coverage, so it carries no fingerprint. */
        fingerprint: null,
        verbatimRun: source.verbatim_run ?? 0
      });

      if (saved) added.push(language);
      else failed.push(language);
    }

    results.push({
      key: group.translation_key,
      status: added.length ? "translated" : "failed",
      from: source.language,
      added,
      failed
    });
  }

  return results;
}
