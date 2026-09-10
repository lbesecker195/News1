import { env } from "../config/env.mjs";
import { escapeHtml, safeURL } from "../utils/html.mjs";

const APP = env.appOrigin;
const ADDRESS = env.businessAddress;

/*
 * The newsletter.
 *
 * Rendered once per reader, because the running order is theirs: the story the
 * model put first becomes the lead, the rest become blurbs underneath.
 *
 * Written as inline-styled table-free HTML with a plain-text alternative.
 * Email clients are not browsers — no stylesheet, no script, no flexbox — so
 * everything here is inline and linear on purpose.
 */

const INK = "#16181d";
const MUTED = "#5b6270";
const LINE = "#e4e6eb";
const ACCENT = "#1a4fd6";

const wrap = body => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>${body.title}</title>
</head>
<body style="margin:0;padding:0;background:#f6f7f9;">
<div style="margin:0 auto;padding:28px 20px;max-width:38rem;background:#ffffff;
            font:16px/1.55 -apple-system,'Segoe UI',system-ui,sans-serif;color:${INK};">
${body.content}
</div>
</body>
</html>`;

export function renderIssueHtml({
  company,
  date,
  stories = [],
  ads = {},
  unsubscribeUrl,
  reader = null
}) {
  const [lead, ...rest] = stories;

  const sections = [
    masthead(company, date),
    lead ? leadStory(lead, reader) : nothingToday(),
    ads.sponsored ? sponsored(ads.sponsored) : "",
    rest.length ? blurbs(rest) : "",
    ...(ads.banners ?? []).map(banner),
    footer(unsubscribeUrl),
    /*
     * Tracking pixels last so a slow or blocked request never delays the copy
     * a reader actually came for.
     */
    ...pixels(ads)
  ];

  return wrap({
    title: `${escapeHtml(company)} — ${escapeHtml(date)}`,
    content: sections.filter(Boolean).join("\n")
  });
}

const masthead = (company, date) => `
<div style="padding-bottom:16px;border-bottom:2px solid ${INK};">
  <div style="font-size:1.35rem;font-weight:700;">${escapeHtml(company)}</div>
  <div style="color:${MUTED};font-size:0.85rem;">${escapeHtml(date)}</div>
</div>`;

const nothingToday = () => `
<p style="padding:24px 0;color:${MUTED};">
  No new coverage matched your topics today.
</p>`;

function leadStory(story, reader) {
  return `
<div style="padding:22px 0 8px;">
  ${reader?.reason
    ? `<div style="color:${ACCENT};font-size:0.72rem;letter-spacing:0.06em;
                   text-transform:uppercase;padding-bottom:6px;">
         Picked for you · ${escapeHtml(reader.reason)}
       </div>`
    : ""}
  <h1 style="margin:0 0 8px;font-size:1.45rem;line-height:1.25;">
    ${escapeHtml(story.headline)}
  </h1>
  <p style="margin:0 0 12px;font-size:1.05rem;color:${MUTED};">
    ${escapeHtml(story.standfirst)}
  </p>
  ${paragraphs(story.body)}
  ${attribution(story)}
</div>`;
}

function blurbs(stories) {
  return `
<div style="padding-top:8px;border-top:1px solid ${LINE};">
  <div style="color:${MUTED};font-size:0.72rem;letter-spacing:0.06em;
              text-transform:uppercase;padding:14px 0 4px;">
    Also today
  </div>
  ${stories.map(story => `
  <div style="padding:12px 0;border-top:1px solid ${LINE};">
    <h2 style="margin:0 0 4px;font-size:1.05rem;">${escapeHtml(story.headline)}</h2>
    <p style="margin:0 0 6px;color:${MUTED};font-size:0.95rem;">
      ${escapeHtml(story.standfirst)}
    </p>
    ${attribution(story)}
  </div>`).join("")}
</div>`;
}

/*
 * The sponsored slot is labelled above the headline, in the reader's line of
 * sight before they start reading it — not in small print underneath. It also
 * carries a visible border so it does not read as editorial.
 */
function sponsored(ad) {
  return `
<div style="margin:20px 0;padding:16px 18px;border:1px solid ${LINE};
            border-left:3px solid ${ACCENT};background:#fbfcfe;">
  <div style="color:${MUTED};font-size:0.7rem;letter-spacing:0.08em;
              text-transform:uppercase;padding-bottom:8px;">
    Sponsored
  </div>
  <h2 style="margin:0 0 6px;font-size:1.1rem;">
    <a href="${escapeHtml(ad.clickUrl)}"
       style="color:${INK};text-decoration:none;">${escapeHtml(ad.headline)}</a>
  </h2>
  <p style="margin:0 0 10px;color:${MUTED};">${escapeHtml(ad.body)}</p>
  <a href="${escapeHtml(ad.clickUrl)}"
     style="color:${ACCENT};font-weight:600;text-decoration:none;">
    ${escapeHtml(ad.cta || "Learn more")} →
  </a>
</div>`;
}

const banner = ad => `
<div style="margin:14px 0;padding:12px 14px;border:1px solid ${LINE};">
  <div style="color:${MUTED};font-size:0.65rem;letter-spacing:0.08em;
              text-transform:uppercase;padding-bottom:4px;">Ad</div>
  <a href="${escapeHtml(ad.clickUrl)}"
     style="color:${INK};text-decoration:none;font-weight:600;">
    ${escapeHtml(ad.headline)}
  </a>
  <div style="color:${MUTED};font-size:0.9rem;">${escapeHtml(ad.body)}</div>
</div>`;

const attribution = story => `
<p style="margin:0;color:${MUTED};font-size:0.82rem;">
  Reported by ${escapeHtml(story.source_name)} ·
  <a href="${escapeHtml(safeURL(story.source_url))}"
     rel="noopener noreferrer" style="color:${ACCENT};">Original coverage</a>
</p>`;

const paragraphs = body => String(body ?? "")
  .split(/\n{2,}/)
  .filter(Boolean)
  .map(part => `<p style="margin:0 0 10px;">${escapeHtml(part.trim())}</p>`)
  .join("");

/*
 * The postal address is a statutory requirement, not a courtesy: every
 * commercial message must carry one. It sits with the unsubscribe link because
 * that is where a reader looks when they want the sender to stop.
 */
const footer = unsubscribeUrl => `
<div style="margin-top:22px;padding-top:14px;border-top:1px solid ${LINE};
            color:${MUTED};font-size:0.8rem;">
  <p style="margin:0 0 6px;">
    Written by Rnews1 from published reporting. Not original journalism —
    follow the links for the publishers' own coverage.
  </p>
  <p style="margin:0 0 6px;">
    <a href="${escapeHtml(APP)}" style="color:${MUTED};">Powered by Rnews1</a>${
  unsubscribeUrl
    ? ` · <a href="${escapeHtml(unsubscribeUrl)}" style="color:${MUTED};">Unsubscribe</a>`
    : ""
}
  </p>
  <p style="margin:0;">Rnews1 &middot; ${escapeHtml(ADDRESS)}</p>
</div>`;

const pixels = ads => [ads.sponsored, ...(ads.banners ?? [])]
  .filter(ad => ad?.pixelUrl)
  .map(ad => `<img src="${escapeHtml(ad.pixelUrl)}" alt="" width="1" height="1"
                    style="display:block;width:1px;height:1px;border:0;">`);

/*
 * The plain-text alternative. Ads appear here too, with their labels intact —
 * a text-only reader is still owed the disclosure.
 */
export function issueText({
  company,
  date,
  stories = [],
  ads = {},
  unsubscribeUrl
}) {
  const lines = [company, date, ""];
  const [lead, ...rest] = stories;

  if (!lead) {
    lines.push("No new coverage matched your topics today.", "");
  } else {
    lines.push(
      lead.headline.toUpperCase(),
      lead.standfirst,
      "",
      String(lead.body ?? "").replace(/\n{2,}/g, "\n\n"),
      "",
      `Reported by ${lead.source_name} — ${safeURL(lead.source_url)}`,
      ""
    );
  }

  if (ads.sponsored) {
    lines.push(
      "— SPONSORED —",
      ads.sponsored.headline,
      ads.sponsored.body,
      ads.sponsored.clickUrl,
      ""
    );
  }

  if (rest.length) {
    lines.push("ALSO TODAY", "");

    for (const story of rest) {
      lines.push(
        story.headline,
        story.standfirst,
        `Reported by ${story.source_name} — ${safeURL(story.source_url)}`,
        ""
      );
    }
  }

  for (const ad of ads.banners ?? []) {
    lines.push(`[Ad] ${ad.headline} — ${ad.body} ${ad.clickUrl}`, "");
  }

  lines.push(
    "Written by Rnews1 from published reporting. Not original journalism.",
    `Powered by Rnews1 — ${APP}`
  );

  if (unsubscribeUrl) lines.push(`Unsubscribe: ${unsubscribeUrl}`);

  lines.push("", `Rnews1, ${ADDRESS}`);

  return lines.join("\n");
}
