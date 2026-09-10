import crypto from "node:crypto";

import { pool, transaction } from "../config/database.mjs";
import { env } from "../config/env.mjs";
import { escapeHtml, safeURL } from "../utils/html.mjs";

export { pool, transaction };
export { escapeHtml, safeURL };

/* The canonical public origin. Every generated link is built from this. */
export const APP = env.appOrigin;

export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

/* 32 bytes of entropy, URL-safe, 43 characters. See isLoginToken(). */
export const token = () => crypto.randomBytes(32).toString("base64url");

/*
 * Used for two unrelated jobs: keying topics by their query, and storing
 * session/login secrets so a database leak does not hand out live sessions.
 */
export const hash = value =>
  crypto.createHash("sha256").update(String(value)).digest("hex");

const DOMAIN = /^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;

/*
 * Accepts what people actually type — "https://www.Example.com/about",
 * "Example.com " — and returns the bare registrable hostname. Throws so the
 * controller can turn it into a 400 with a useful message.
 */
export function companyDomain(input) {
  let value = String(input ?? "").trim().toLowerCase();

  if (!value) {
    throw new Error("A company domain is required.");
  }

  if (value.includes("@")) {
    value = value.slice(value.lastIndexOf("@") + 1);
  }

  if (/^[a-z][a-z0-9+.-]*:\/\//.test(value)) {
    try {
      value = new URL(value).hostname;
    } catch {
      throw new Error("Invalid company domain.");
    }
  }

  value = value.split("/")[0].split("?")[0].split("#")[0];
  value = value.split(":")[0];
  value = value.replace(/^www\./, "").replace(/\.$/, "");

  if (!DOMAIN.test(value)) {
    throw new Error("Invalid company domain.");
  }

  return value;
}

/*
 * The one place outgoing mail is created. Callers pass a transaction client so
 * an email is only queued if the state change that justifies it also commits.
 *
 * dedupeKey makes re-running a scheduler harmless: the unique index turns a
 * second insert into a no-op instead of a second email.
 */
export async function enqueue(db, {
  tenantId = null,
  contactId = null,
  toEmail,
  kind,
  payload = {},
  runAfter = null,
  expiresAt = null,
  dedupeKey = null
}) {
  const { rows } = await db.query(
    `INSERT INTO outbox(
       tenant_id, contact_id, to_email, kind, payload,
       run_after, expires_at, dedupe_key
     )
     VALUES($1,$2,$3,$4,$5,COALESCE($6,now()),$7,$8)
     ON CONFLICT (dedupe_key) DO NOTHING
     RETURNING id`,
    [
      tenantId,
      contactId,
      toEmail,
      kind,
      JSON.stringify(payload),
      runAfter,
      expiresAt,
      dedupeKey
    ]
  );

  return rows[0]?.id ?? null;
}

export { aiJSON } from "./openai.service.mjs";
export { sendEmail } from "./mailer.service.mjs";
export { renderIssueHtml, issueText } from "./brief.service.mjs";
export {
  writeBriefPdf,
  briefPdfPath,
  deleteBriefPdf,
  closeBrowser
} from "./pdf.service.mjs";
export { campaignHealth, assertCampaignHealthy } from "./campaign.service.mjs";
