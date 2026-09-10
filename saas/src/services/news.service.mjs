import crypto from "node:crypto";

import { env } from "../config/env.mjs";

/*
 * Finding the day's candidate stories.
 *
 * This used to read Google News RSS. It no longer can: Google stopped
 * redirecting to publishers and now serves a JavaScript interstitial that
 * resolves the target through an internal API, so an RSS item's link leads
 * only back to Google. Without a publisher URL there is no article to read.
 *
 * Discovery now goes through treg, which returns the publisher's own URL. Two
 * providers serve the same job and either can be selected with NEWS_PROVIDER:
 *
 *   exa   neural search, $0.007 per call. Returns genuine recent news and a
 *         real publishedDate, and takes a date floor so "today" means today.
 *   serp  Google News via DataForSEO, $0.002 per call. Cheaper, ranks the way
 *         Google News ranks — which mixes market reports and listicles in
 *         among the reporting.
 *
 * Failure here is never fatal. An empty list means a thin issue, not a dead
 * worker, and a provider outage should not stop the mail.
 */

const TIMEOUT_MS = 20_000;
const MAX_ITEMS = 12;

/* How far back a "recent" story may be. Two days covers a weekend gap. */
const RECENCY_DAYS = 2;

export const PROVIDERS = {
  exa: "exa.web.search.news",
  serp: "treg.google.serp.news"
};

/*
 * The stored topic query is Google's syntax — "a" OR "b" OR "c" — because that
 * is what it was built for. Exa is a neural search and reads plain language
 * better than boolean, so the operators come out for it.
 */
export const plainQuery = query => String(query ?? "")
  .replace(/"/g, " ")
  .replace(/\bOR\b/gi, " ")
  .replace(/\s+/g, " ")
  .trim();

export async function fetchTopicItems({
  query,
  language = "en",
  since = null,
  provider = env.newsProvider
} = {}) {
  if (!query) return [];

  const endpoint = PROVIDERS[provider] ?? PROVIDERS.exa;

  const floor = since ?? new Date(
    Date.now() - RECENCY_DAYS * 86_400_000
  ).toISOString();

  try {
    const body = provider === "serp"
      ? { q: query, language, country: "us" }
      : {
        query: plainQuery(query),
        category: "news",
        numResults: MAX_ITEMS,
        startPublishedDate: floor
      };

    const response = await callTreg(endpoint, body);

    const items = provider === "serp"
      ? fromSerp(response)
      : fromExa(response);

    return dedupe(items).slice(0, MAX_ITEMS);
  } catch (error) {
    console.error(`News discovery failed (${provider}): ${error.message}`);
    return [];
  }
}

async function callTreg(endpoint, body) {
  if (!env.tregToken) {
    throw new Error("TREG_TOKEN is not set");
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const response = await fetch(`${env.tregBaseUrl}/call/${endpoint}`, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "x-treg-token": env.tregToken,
        "content-type": "application/json"
      },
      body: JSON.stringify(body)
    });

    const text = await response.text();

    if (!response.ok) {
      /*
       * 402 is an empty balance and 503 is the provider being out of capacity.
       * Both are operational problems someone has to act on, so they are worth
       * saying plainly rather than burying in a generic failure.
       */
      const hint = response.status === 402
        ? " — treg balance is empty, top up at treg.to"
        : response.status === 503
          ? " — provider capacity unavailable, try the other NEWS_PROVIDER"
          : "";

      throw new Error(
        `treg ${response.status}${hint}: ${text.replace(/\s+/g, " ").slice(0, 200)}`
      );
    }

    const cost = Number(response.headers.get("x-treg-cost-micro") ?? 0);

    if (cost) {
      console.log(
        `treg ${endpoint}: $${(cost / 1_000_000).toFixed(4)} ` +
        `(call ${response.headers.get("x-treg-call-id") ?? "?"})`
      );
    }

    return JSON.parse(text);
  } finally {
    clearTimeout(timer);
  }
}

/* ---- provider shapes ---------------------------------------------------- */

function fromExa(payload) {
  return (Array.isArray(payload?.results) ? payload.results : [])
    .map(row => item({
      url: row.url,
      title: row.title,
      publisher: publisherFrom(row.url),
      published: row.publishedDate
    }));
}

/*
 * A routed treg call answers as {output, raw, _treg}; a direct child answers in
 * the provider's own shape. Both are accepted so switching between them does
 * not need a code change.
 */
function fromSerp(payload) {
  const rows = payload?.output?.results ??
    payload?.results ??
    payload?.raw?.results ??
    [];

  return (Array.isArray(rows) ? rows : [])
    .filter(row => row?.url)
    .map(row => item({
      url: row.url,
      title: row.title,
      publisher: row.domain ? String(row.domain).replace(/^www\./, "")
        : publisherFrom(row.url),
      published: row.timestamp ?? row.time_published
    }));
}

function item({ url, title, publisher, published }) {
  const when = Date.parse(published);

  return {
    /* Stable across runs, so a re-crawled article merges onto itself. */
    id: crypto.createHash("sha1").update(String(url)).digest("hex").slice(0, 16),
    title: String(title ?? "").trim(),
    url: String(url ?? ""),
    source: publisher || "Unknown",
    published: new Date(Number.isNaN(when) ? Date.now() : when).toISOString(),
    summary: ""
  };
}

export function publisherFrom(url) {
  try {
    return new URL(url).host.replace(/^www\./, "");
  } catch {
    return "Unknown";
  }
}

function dedupe(items) {
  const seen = new Set();

  return items
    .filter(entry => {
      if (!entry.url || !entry.title || seen.has(entry.url)) return false;

      seen.add(entry.url);
      return true;
    })
    .sort((a, b) => Date.parse(b.published) - Date.parse(a.published));
}

/*
 * Newly found items win, but older ones are retained so that article links
 * already mailed out keep resolving. Ids are derived from the article URL, so
 * a re-crawled article merges onto itself.
 */
export function mergeItems(existing, fresh, limit = 60) {
  const merged = [];
  const seen = new Set();

  for (const entry of [...fresh, ...(Array.isArray(existing) ? existing : [])]) {
    if (!entry?.id || seen.has(entry.id)) continue;

    seen.add(entry.id);
    merged.push(entry);
  }

  return merged
    .sort((a, b) => Date.parse(b.published) - Date.parse(a.published))
    .slice(0, limit);
}
