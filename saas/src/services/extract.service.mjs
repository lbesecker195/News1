import { env } from "../config/env.mjs";

/*
 * Fetching the article behind a headline.
 *
 * Three things this does deliberately, because the alternative in each case is
 * the kind of scraping that gets a sending domain blocked and a company sued:
 *
 *   1. It obeys robots.txt. Not a legal obligation in most places, but the
 *      cheapest possible evidence of good faith, and the first thing anyone
 *      asks about.
 *   2. It identifies itself honestly, with a contactable URL in the agent
 *      string. A publisher who wants us gone can say so.
 *   3. It never persists the publisher's text. The body is held only long
 *      enough to write from and is then dropped — see story.service.mjs.
 *
 * Extraction degrades rather than fails: no body means the story is written
 * from the headline, exactly as it was before, and the issue still ships.
 */

const AGENT =
  `Rnews1/1.0 (+${env.appOrigin}/about; newsletter summarisation)`;

const FETCH_TIMEOUT_MS = 15_000;
const ROBOTS_TIMEOUT_MS = 5_000;

/* Enough for any news article; a defence against a hostile or broken URL. */
const MAX_BYTES = 2_000_000;

/* What we hand the model. Beyond this adds cost without adding context. */
export const MAX_BODY_CHARS = 8_000;

const MIN_USEFUL_CHARS = 400;

/* ---- robots.txt --------------------------------------------------------- */

const robotsCache = new Map();
const ROBOTS_TTL_MS = 3_600_000;

/*
 * A deliberately small robots parser: the group matching our agent if there is
 * one, otherwise the wildcard group, and only Disallow/Allow within it. It errs
 * towards allowing — a missing or unparseable robots.txt is not a prohibition,
 * and a fetch failure must not silently stop the whole pipeline.
 */
export async function isAllowed(url) {
  let target;

  try {
    target = new URL(url);
  } catch {
    return false;
  }

  if (!["http:", "https:"].includes(target.protocol)) return false;

  const rules = await robotsFor(target.origin);

  if (!rules) return true;

  const path = `${target.pathname}${target.search}`;

  /* Longest match wins, which is how the de-facto standard resolves it. */
  let verdict = true;
  let longest = -1;

  for (const rule of rules) {
    if (!rule.path || !path.startsWith(rule.path)) continue;
    if (rule.path.length <= longest) continue;

    longest = rule.path.length;
    verdict = rule.allow;
  }

  return verdict;
}

async function robotsFor(origin) {
  const cached = robotsCache.get(origin);

  if (cached && cached.until > Date.now()) return cached.rules;

  let rules = null;

  try {
    const response = await fetchWithTimeout(
      `${origin}/robots.txt`,
      ROBOTS_TIMEOUT_MS
    );

    /* 4xx means no restrictions published. 5xx we also treat as allowed. */
    if (response.ok) {
      rules = parseRobots(await response.text());
    }
  } catch {
    /* Unreachable robots.txt is not a prohibition. */
  }

  robotsCache.set(origin, { rules, until: Date.now() + ROBOTS_TTL_MS });

  return rules;
}

export function parseRobots(text) {
  const groups = [];
  let current = null;

  for (const raw of String(text).split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, "").trim();

    if (!line) continue;

    const [field, ...rest] = line.split(":");
    const key = field.trim().toLowerCase();
    const value = rest.join(":").trim();

    if (key === "user-agent") {
      /* Consecutive user-agent lines share one group of rules. */
      if (!current || current.rules.length) {
        current = { agents: [], rules: [] };
        groups.push(current);
      }

      current.agents.push(value.toLowerCase());
      continue;
    }

    if (!current) continue;

    if (key === "disallow") current.rules.push({ path: value, allow: false });
    if (key === "allow") current.rules.push({ path: value, allow: true });
  }

  const ours = groups.find(group =>
    group.agents.some(agent => agent.includes("rnews1")));

  const wildcard = groups.find(group => group.agents.includes("*"));

  return (ours ?? wildcard)?.rules ?? null;
}

/* ---- fetching ----------------------------------------------------------- */

function fetchWithTimeout(url, timeoutMs, init = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  return fetch(url, {
    redirect: "follow",
    ...init,
    signal: controller.signal,
    headers: {
      "user-agent": AGENT,
      accept: "text/html,application/xhtml+xml",
      "accept-language": "en",
      ...init.headers
    }
  }).finally(() => clearTimeout(timer));
}

/*
 * Google News links are redirects. Following them normally resolves to the
 * publisher; when it does not, the older link format carries the target URL
 * base64 inside the path, which is worth one attempt before giving up.
 */
export function decodeGoogleNewsUrl(url) {
  const match = String(url).match(/news\.google\.com\/rss\/articles\/([\w-]+)/);

  if (!match) return null;

  try {
    const decoded = Buffer.from(match[1], "base64url").toString("latin1");
    const found = decoded.match(/https?:\/\/[^\s\x00-\x1f"'<>]+/);

    if (!found) return null;

    /* Trailing bytes of the protobuf frame often ride along on the URL. */
    return new URL(found[0].replace(/[^\w\-./:?=&%~+#@]+$/, "")).href;
  } catch {
    return null;
  }
}

/* ---- extraction --------------------------------------------------------- */

/*
 * Returns { url, text, method, chars } or null when nothing usable was found.
 * Never throws: every failure path degrades to a headline-only rewrite.
 */
export async function fetchArticle(link) {
  try {
    const direct = await resolve(link);

    if (!direct) return null;

    if (!await isAllowed(direct.url)) {
      return { url: direct.url, text: null, method: "robots_denied", chars: 0 };
    }

    const found = extractArticleText(direct.html);

    if (!found) {
      return { url: direct.url, text: null, method: "no_content", chars: 0 };
    }

    return {
      url: direct.url,
      text: found.text.slice(0, MAX_BODY_CHARS),
      method: found.method,
      chars: found.text.length
    };
  } catch (error) {
    console.warn(`Article fetch failed: ${error.message}`);
    return null;
  }
}

async function resolve(link) {
  const attempts = [link, decodeGoogleNewsUrl(link)].filter(Boolean);

  for (const attempt of attempts) {
    const response = await fetchWithTimeout(attempt, FETCH_TIMEOUT_MS)
      .catch(() => null);

    if (!response?.ok) continue;

    const type = response.headers.get("content-type") ?? "";

    if (!type.includes("html")) continue;

    const finalUrl = response.url || attempt;

    /* Still on the redirector: this attempt told us nothing. */
    if (/(^|\.)news\.google\.com$/.test(new URL(finalUrl).host)) continue;

    const html = await readCapped(response);

    if (html) return { url: finalUrl, html };
  }

  return null;
}

async function readCapped(response) {
  const reader = response.body?.getReader();

  if (!reader) return response.text();

  const chunks = [];
  let total = 0;

  while (total < MAX_BYTES) {
    const { done, value } = await reader.read();

    if (done) break;

    total += value.length;
    chunks.push(value);
  }

  reader.cancel().catch(() => {});

  return Buffer.concat(chunks.map(Buffer.from)).toString("utf8");
}

/*
 * Extraction, best source first. Returns { text, method } or null.
 *
 * JSON-LD is tried first because most news sites publish articleBody there and
 * it is already clean prose — no navigation, no cookie banner, no related-links
 * rail. The DOM heuristics below it are the fallback for sites that do not.
 *
 * The method travels with the text because it is worth knowing later which
 * publishers we read cleanly and which we are scraping by guesswork.
 */
const STRATEGIES = [
  ["jsonld", fromJsonLd],
  ["articletag", fromArticleTag],
  ["paragraphs", fromParagraphs]
];

export function extractArticleText(html) {
  for (const [method, strategy] of STRATEGIES) {
    const text = strategy(html);

    if (text && text.length >= MIN_USEFUL_CHARS) return { text, method };
  }

  return null;
}

function fromJsonLd(html) {
  const blocks = [...String(html).matchAll(
    /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi
  )];

  for (const [, raw] of blocks) {
    let parsed;

    try {
      parsed = JSON.parse(raw.trim());
    } catch {
      continue;
    }

    const found = findArticleBody(parsed);

    if (found) return clean(found);
  }

  return null;
}

function findArticleBody(node, depth = 0) {
  if (!node || depth > 6) return null;

  if (Array.isArray(node)) {
    for (const entry of node) {
      const found = findArticleBody(entry, depth + 1);
      if (found) return found;
    }

    return null;
  }

  if (typeof node !== "object") return null;

  if (typeof node.articleBody === "string" && node.articleBody.length > 200) {
    return node.articleBody;
  }

  for (const key of ["@graph", "mainEntity", "mainEntityOfPage"]) {
    const found = findArticleBody(node[key], depth + 1);
    if (found) return found;
  }

  return null;
}

function fromArticleTag(html) {
  const match = String(html).match(/<article\b[^>]*>([\s\S]*?)<\/article>/i);

  return match ? paragraphsFrom(match[1]) : null;
}

function fromParagraphs(html) {
  return paragraphsFrom(String(html));
}

function paragraphsFrom(fragment) {
  const stripped = String(fragment)
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<(nav|aside|footer|header|figure|form)[\s\S]*?<\/\1>/gi, " ");

  const paragraphs = [...stripped.matchAll(/<p\b[^>]*>([\s\S]*?)<\/p>/gi)]
    .map(([, inner]) => clean(inner))
    /* Short fragments are captions, bylines and cookie notices. */
    .filter(text => text.length > 60);

  return paragraphs.length ? paragraphs.join("\n\n") : null;
}

const ENTITIES = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
  rsquo: "’", lsquo: "‘", ldquo: "“", rdquo: "”",
  mdash: "—", ndash: "–", hellip: "…"
};

function clean(value) {
  return String(value)
    .replace(/<[^>]*>/g, " ")
    .replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, entity) => {
      const key = entity.toLowerCase();

      if (key in ENTITIES) return ENTITIES[key];
      if (key.startsWith("#x")) {
        return String.fromCodePoint(parseInt(key.slice(2), 16));
      }
      if (key.startsWith("#")) return String.fromCodePoint(Number(key.slice(1)));

      return match;
    })
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
