import { pathToFileURL } from "node:url";

import { pool } from "../config/database.mjs";
import { env, requireEnv, WORKER_ENV } from "../config/env.mjs";

import * as briefs from "../models/brief.model.mjs";
import * as digests from "../models/digest.model.mjs";
import * as outbox from "../models/outbox.model.mjs";
import * as paypalEvents from "../models/paypal-event.model.mjs";
import * as topics from "../models/topic.model.mjs";

import {
  APP,
  assertCampaignHealthy,
  closeBrowser,
  deleteBriefPdf,
  enqueue,
  escapeHtml,
  issueText,
  renderIssueHtml,
  sendEmail,
  sleep,
  writeBriefPdf
} from "../services/platform.service.mjs";

import { fetchTopicItems, mergeItems } from "../services/news.service.mjs";
import { renderBriefPage } from "../services/brief-page.service.mjs";
import { buildIssue, pickForContact } from "../services/story.service.mjs";
import { selectAds } from "../services/ad.service.mjs";
import * as ads from "../models/ad.model.mjs";
import * as storyModel from "../models/story.model.mjs";
import { transaction } from "../config/database.mjs";
import {
  MailgunUnknownError,
  verifyMailgun
} from "../services/mailer.service.mjs";

const DIGEST_ITEMS = 8;

const INTERVALS = {
  content: 30_000,
  delivery: 2_000,
  scheduler: 60_000,
  maintenance: 600_000
};

/* ---- Content ------------------------------------------------------------ */

export async function refreshOneTopic() {
  const topic = await topics.claimStaleTopic();

  if (!topic) return null;

  try {
    const fresh = await fetchTopicItems({
      query: topic.query,
      language: topic.language
    });

    /*
     * Old items are kept alongside the new ones so that article links already
     * mailed out in a digest keep resolving for the life of the brief.
     */
    const merged = mergeItems(topic.items, fresh);

    await topics.saveItems(topic.key, merged);

    return { key: topic.key, fetched: fresh.length, total: merged.length };
  } catch (error) {
    console.error(`Topic ${topic.key} refresh failed:`, error.message);
    await topics.recordFailure(topic.key, error.message);

    return { key: topic.key, error: error.message };
  }
}

/* ---- Scheduling --------------------------------------------------------- */

const utcDate = (at = new Date()) => at.toISOString().slice(0, 10);

/*
 * Queues one tenant's digest per call, so a slow batch never blocks the loop.
 * Returns null when nothing is due, which is the signal to stop draining.
 */
export async function scheduleDigests(now = new Date()) {
  if (now.getUTCHours() < env.digestHour) return null;

  const date = utcDate(now);

  /*
   * The day's three stories are written once per topic, before any recipient is
   * considered. Everything after this is arrangement, not authorship.
   */
  const scheduled = await digests.withTenantDueForDigest(date, async (tenant, db) => {
    for (const recipient of tenant.recipients) {
      await enqueue(db, {
        tenantId: tenant.id,
        contactId: recipient.contact_id,
        toEmail: recipient.email,
        kind: "digest",
        /*
         * Deliberately thin. The issue is assembled at delivery time, so the
         * payload carries identifiers rather than a rendered newsletter per
         * recipient — and an ad is only counted as delivered if the message
         * that carries it is actually sent.
         */
        payload: {
          company: tenant.name,
          topicKey: tenant.topic_key,
          unsubscribeUrl: `${APP}/u/${recipient.unsub_token}`,
          date
        },
        expiresAt: new Date(Date.now() + 36 * 3600_000),
        dedupeKey: `digest:${tenant.id}:${recipient.contact_id}:${date}`
      });
    }

    return {
      tenantId: tenant.id,
      topicKey: tenant.topic_key,
      topicQuery: tenant.topic_query,
      language: tenant.language,
      company: tenant.name || "Your company",
      date,
      recipients: tenant.recipients.length
    };
  });

  if (!scheduled) return null;

  /*
   * Written after the transaction commits so a rolled-back issue cannot leave
   * a brief, or a PDF on disk, with nothing pointing at it.
   */
  let stories = [];

  try {
    stories = await buildIssue({
      topicKey: scheduled.topicKey,
      query: scheduled.topicQuery,
      language: scheduled.language,
      issueDate: scheduled.date
    });
  } catch (error) {
    console.error(`Issue for ${scheduled.topicKey} failed:`, error.message);
  }

  /*
   * The canonical issue: default running order, no advertising. This is what
   * /brief/:id serves and what the PDF is made from, so there is always one
   * version of the day that is the same for everyone.
   */
  try {
    const html = renderIssueHtml({
      company: scheduled.company,
      date: scheduled.date,
      stories
    });

    const briefId = await transaction(db => briefs.create(db, {
      tenantId: scheduled.tenantId,
      html,
      /* Kept so the report page can be laid out from data, not from email. */
      storyIds: stories.map(story => story.id),
      issueDate: scheduled.date
    }));

    /* The PDF is the landing page, printed — same renderer as /brief/:id. */
    const page = await renderBriefPage(await briefs.findUnexpired(briefId));

    await writeBriefPdf(briefId, page.html, page.content.print);
    await briefs.markPdfWritten(briefId);

    scheduled.briefId = briefId;
  } catch (error) {
    console.error(`Brief for ${scheduled.tenantId} failed:`, error.message);
  }

  scheduled.stories = stories.length;

  return scheduled;
}

/*
 * Queues the outbound campaign for a future date. Separate from the digest
 * path on purpose: it is run by hand, for a date the operator names, and it
 * only ever touches contacts that are not suppressed.
 */
export async function planCampaign(date, { limit = 500 } = {}) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(date))) {
    throw new Error("Usage: npm run plan -- YYYY-MM-DD");
  }

  const runAfter = new Date(`${date}T14:00:00Z`);

  if (Number.isNaN(runAfter.getTime())) {
    throw new Error(`${date} is not a real date.`);
  }

  const contacts = await digests.listCampaignContacts(limit);

  let queued = 0;

  for (const contact of contacts) {
    const id = await enqueue(pool, {
      contactId: contact.id,
      toEmail: contact.email,
      kind: "campaign",
      payload: {
        name: contact.name,
        company: contact.company,
        unsubscribeUrl: `${APP}/u/${contact.unsub_token}`
      },
      runAfter,
      expiresAt: new Date(runAfter.getTime() + 7 * 86400_000),
      dedupeKey: `campaign:${contact.id}:${date}`
    });

    if (id) queued++;
  }

  return { date, eligible: contacts.length, queued };
}

/* ---- Delivery ----------------------------------------------------------- */

/*
 * Thrown for a message that will never build — an unknown kind, say. The
 * delivery loop fails these immediately instead of spending five attempts
 * rediscovering that nothing has changed.
 */
export class UnbuildableMessage extends Error {
  constructor(message) {
    super(message);
    this.name = "UnbuildableMessage";
  }
}

export async function buildMessage(job) {
  const payload = job.payload || {};

  switch (job.kind) {
    case "login":
      return {
        subject: "Your Rnews1 sign-in link",
        text: [
          "Use this link to sign in to Rnews1:",
          payload.url,
          "",
          "The link expires in 20 minutes and can only be used once.",
          "If you did not request it, you can ignore this email."
        ].join("\n"),
        html: paragraphs([
          "Use this link to sign in to Rnews1:",
          link(payload.url, "Sign in to Rnews1"),
          "The link expires in 20 minutes and can only be used once.",
          "If you did not request it, you can ignore this email."
        ]),
        tag: "login"
      };

    case "confirmation":
      return {
        subject: `Confirm your ${payload.company || "company"} briefing`,
        text: [
          `${payload.company || "A company"} has invited you to receive a`,
          "daily Rnews1 news briefing.",
          "",
          "Confirm here:",
          payload.url,
          "",
          "If you did not expect this, ignore this email and nothing is sent."
        ].join("\n"),
        html: paragraphs([
          `${escapeHtml(payload.company || "A company")} has invited you to ` +
          "receive a daily Rnews1 news briefing.",
          link(payload.url, "Confirm my subscription"),
          "If you did not expect this, ignore this email and nothing is sent."
        ]),
        tag: "confirmation"
      };

    case "digest":
      return buildIssueMessage(job, payload);

    case "campaign":
      return {
        subject: "One useful daily briefing for your team",
        text: [
          payload.name ? `Hi ${payload.name},` : "Hello,",
          "",
          "Rnews1 turns the topics your company follows into a shared news",
          "feed, a website embed, and a daily email for your team.",
          "$25 a month, unlimited recipients, cancel online.",
          "",
          APP,
          "",
          `Unsubscribe: ${payload.unsubscribeUrl}`,
          "",
          `Rnews1, ${env.businessAddress}`
        ].join("\n"),
        html: paragraphs([
          escapeHtml(payload.name ? `Hi ${payload.name},` : "Hello,"),
          "Rnews1 turns the topics your company follows into a shared news " +
          "feed, a website embed, and a daily email for your team. " +
          "$25 a month, unlimited recipients, cancel online.",
          link(APP, "See how it works"),
          link(payload.unsubscribeUrl, "Unsubscribe"),
          escapeHtml(`Rnews1 · ${env.businessAddress}`)
        ]),
        tag: "campaign",
        headers: unsubscribeHeaders(payload.unsubscribeUrl)
      };

    default:
      throw new UnbuildableMessage(`Unknown outbox kind: ${job.kind}`);
  }
}

/*
 * One reader's issue, assembled now rather than at scheduling time.
 *
 * Two things have to happen in this order: the model decides which of the day's
 * stories leads for this person, then the ad slots are filled and recorded. The
 * placement rows are written in a transaction with nothing else, so an ad is
 * only ever counted against a message that is about to be handed to Mailgun.
 */
async function buildIssueMessage(job, payload) {
  const company = payload.company || "Your company";
  const date = payload.date;

  const dayStories = payload.topicKey
    ? await storyModel.forIssue(payload.topicKey, date)
    : [];

  const contact = job.contact_id
    ? (await pool.query(
      "SELECT id, name, title, company, industry FROM contacts WHERE id=$1",
      [job.contact_id]
    )).rows[0]
    : null;

  let ordered = dayStories;
  let reason = null;

  if (contact && dayStories.length) {
    ordered = await pickForContact({
      contact,
      topicKey: payload.topicKey,
      issueDate: date,
      pool: dayStories
    });

    const picks = await storyModel.findPicks(contact.id, payload.topicKey, date);
    reason = picks?.personalised ? picks.reason : null;
  }

  const placed = await transaction(db => selectAds(db, {
    contact,
    tenantId: job.tenant_id,
    issueDate: date,
    topicTerms: topicTerms(payload)
  }));

  const issue = {
    company,
    date,
    stories: ordered,
    ads: placed,
    unsubscribeUrl: payload.unsubscribeUrl,
    reader: reason ? { reason } : null
  };

  return {
    subject: ordered[0]
      ? `${ordered[0].headline}`
      : `${company} — ${date}`,
    text: issueText(issue),
    html: renderIssueHtml(issue),
    tag: "digest",
    headers: unsubscribeHeaders(payload.unsubscribeUrl)
  };
}

/* Contextual ad targeting reads the terms the issue is actually about. */
const topicTerms = payload =>
  String(payload.topicQuery ?? "")
    .match(/"([^"]+)"/g)
    ?.map(term => term.replace(/"/g, "")) ?? [];

/*
 * RFC 8058. The POST variant is what lets a mail client unsubscribe without
 * opening a browser, and is why POST /u/:token carries no origin check.
 */
function unsubscribeHeaders(url) {
  if (!url) return {};

  return {
    "List-Unsubscribe": `<${url}>`,
    "List-Unsubscribe-Post": "List-Unsubscribe=One-Click"
  };
}

const link = (url, label) =>
  `<a href="${escapeHtml(url)}">${escapeHtml(label)}</a>`;

const paragraphs = lines => `<!doctype html>
<html lang="en"><body style="font:16px/1.55 -apple-system,system-ui,sans-serif;
color:#16181d;max-width:34rem;margin:0 auto;padding:24px">
${lines.map(line => `<p>${line}</p>`).join("\n")}
</body></html>`;

export async function deliverOne() {
  const job = await outbox.claimJob();

  if (!job) return null;

  /*
   * Campaign volume is throttled by deliverability, not by the queue. If the
   * recent numbers look bad the job goes back unspent rather than failing.
   */
  if (job.kind === "campaign") {
    const reason = await assertCampaignHealthy();

    if (reason) {
      console.warn(`Campaign paused: ${reason}`);
      await outbox.deferJob(job.id, 360, reason);
      return { id: job.id, deferred: true };
    }
  }

  if (job.contact_id && job.kind !== "login") {
    const { rows } = await pool.query(
      `SELECT opted_out_at, bounced_at FROM contacts WHERE id=$1`,
      [job.contact_id]
    );

    const contact = rows[0];

    /* Last check before the send; the queue may have been sitting for hours. */
    if (!contact || contact.opted_out_at || contact.bounced_at) {
      await outbox.markSuppressed(job.id, "recipient suppressed");
      return { id: job.id, suppressed: true };
    }
  }

  let message;

  try {
    message = await buildMessage(job);
  } catch (error) {
    /*
     * Only a structurally impossible message is failed outright. Assembling an
     * issue now touches the database and the model, and those failures are
     * transient — failing them permanently would silently drop a send.
     */
    if (error instanceof UnbuildableMessage) {
      await outbox.markFailed(job.id, error.message);
      return { id: job.id, failed: true };
    }

    if (job.attempts < outbox.MAX_ATTEMPTS) {
      await outbox.retryLater(job.id, job.attempts, error.message);
      return { id: job.id, retrying: true };
    }

    await outbox.markFailed(job.id, error.message);
    return { id: job.id, failed: true };
  }

  try {
    const { messageId } = await sendEmail({
      to: job.to_email,
      jobId: job.id,
      ...message
    });

    await outbox.markAccepted(job.id, messageId);

    return { id: job.id, accepted: true };
  } catch (error) {
    if (error instanceof MailgunUnknownError) {
      /*
       * The message may or may not have been accepted. Retrying could send it
       * twice, so it is parked for the events webhook to resolve.
       */
      await outbox.markUnknown(job.id, error.message);
      return { id: job.id, unknown: true };
    }

    if (error.retryable && job.attempts < outbox.MAX_ATTEMPTS) {
      await outbox.retryLater(job.id, job.attempts, error.message);
      return { id: job.id, retrying: true };
    }

    await outbox.markFailed(job.id, error.message);
    return { id: job.id, failed: true };
  }
}

/* ---- Maintenance -------------------------------------------------------- */

export async function maintenance() {
  const requeued = await outbox.requeueStuck();
  const exhausted = await outbox.failExhausted();
  const expired = await outbox.expireStale();

  await outbox.pruneAuth();
  await outbox.prune();
  await outbox.pruneEvents();
  await paypalEvents.prune();
  await topics.parkUnused();
  const campaigns = await ads.completeFinishedCampaigns();

  const removed = await briefs.deleteExpired();

  for (const brief of removed) {
    if (!brief.has_pdf) continue;

    await deleteBriefPdf(brief.id).catch(error => {
      console.error(`Could not remove PDF ${brief.id}:`, error.message);
    });
  }

  return {
    requeued,
    exhausted,
    expired,
    campaigns,
    briefs: removed.length
  };
}

/* ---- Loops -------------------------------------------------------------- */

let running = true;

/*
 * Each loop drains its queue, then waits. Errors are logged and the loop
 * continues: one bad topic or one unreachable API must not stop delivery.
 */
async function loop(name, step, intervalMs, { drain = false } = {}) {
  while (running) {
    try {
      if (drain) {
        /* Bounded so a large backlog cannot starve the shutdown check. */
        for (let n = 0; n < 100 && running; n++) {
          if (!await step()) break;
        }
      } else {
        await step();
      }
    } catch (error) {
      console.error(`${name} loop error:`, error);
    }

    await interruptibleSleep(intervalMs);
  }
}

const sleepers = new Set();

/* Shutdown must not wait out a ten-minute maintenance interval. */
function wake() {
  for (const resolve of [...sleepers]) resolve();
}

function interruptibleSleep(ms) {
  return new Promise(resolve => {
    const finish = () => {
      clearTimeout(timer);
      sleepers.delete(finish);
      resolve();
    };

    const timer = setTimeout(finish, ms);

    sleepers.add(finish);
  });
}

export const contentLoop = () =>
  loop("content", refreshOneTopic, INTERVALS.content, { drain: true });

export const deliveryLoop = () =>
  loop("delivery", deliverOne, INTERVALS.delivery, { drain: true });

export const schedulerLoop = () =>
  loop("scheduler", scheduleDigests, INTERVALS.scheduler, { drain: true });

export const maintenanceLoop = () =>
  loop("maintenance", maintenance, INTERVALS.maintenance);

/* ---- Entry point -------------------------------------------------------- */

async function main() {
  requireEnv(...WORKER_ENV);

  const args = process.argv.slice(2);

  if (args.includes("--plan")) {
    const date = args.find(value => /^\d{4}-\d{2}-\d{2}$/.test(value));

    console.log(await planCampaign(date));
    await pool.end();
    return;
  }

  if (args.includes("--once")) {
    console.log("content:", await refreshOneTopic());
    console.log("scheduler:", await scheduleDigests());
    console.log("delivery:", await deliverOne());
    console.log("maintenance:", await maintenance());
    await closeBrowser();
    await pool.end();
    return;
  }

  /*
   * Checked once, at boot. A key that cannot send is a configuration problem
   * to fix now, not a queue of failed jobs to discover tomorrow.
   */
  try {
    const mailgun = await verifyMailgun();

    console.log(
      `Mailgun ready: ${mailgun.domain} (${mailgun.state})` +
      (mailgun.sandbox
        ? " — sandbox domain, delivers only to authorised recipients"
        : "")
    );
  } catch (error) {
    console.error(
      `Startup failed: ${error.message}\n` +
      "  Check MAILGUN_API_KEY and MAILGUN_DOMAIN.\n" +
      "  To work without mail, run the web app and use: npm run login"
    );

    await pool.end().catch(() => {});
    process.exit(1);
  }

  console.log("Rnews1 worker started.");

  const stop = async signal => {
    if (!running) return;

    console.log(`Received ${signal}; finishing current work.`);
    running = false;
    wake();

    setTimeout(() => {
      console.error("Worker shutdown timed out; exiting.");
      process.exit(1);
    }, 15_000).unref();
  };

  process.on("SIGTERM", () => stop("SIGTERM"));
  process.on("SIGINT", () => stop("SIGINT"));

  await Promise.all([
    contentLoop(),
    deliveryLoop(),
    schedulerLoop(),
    maintenanceLoop()
  ]);

  await closeBrowser();
  await pool.end();
  console.log("Worker stopped.");
}

/* Importing this module for its functions must not start the loops. */
if (process.argv[1] &&
    import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    await main();
  } catch (error) {
    /* A misconfiguration or a bad argument, not a crash worth a stack dump. */
    console.error(`Worker failed: ${error.message}`);
    await pool.end().catch(() => {});
    process.exit(1);
  }
}
