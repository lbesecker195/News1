import { z } from "zod";

import * as admins from "../models/admin.model.mjs";
import * as ads from "../models/ad.model.mjs";
import { pool } from "../config/database.mjs";

import { APP, hash, token } from "../services/platform.service.mjs";
import { ADMIN_COOKIE } from "../middleware/admin.middleware.mjs";
import { HttpError } from "../utils/http-error.mjs";
import { readCookie } from "../utils/cookies.mjs";
import { emailSchema } from "../utils/validation.mjs";

const COOKIE = {
  httpOnly: true,
  secure: APP.startsWith("https://"),
  sameSite: "lax",
  path: "/admin"
};

export function showLogin(req, res) {
  res.set("Cache-Control", "no-store").render("admin/login", {
    title: "Staff sign in",
    error: null
  });
}

export async function login(req, res) {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const password = String(req.body?.password ?? "");

  const admin = await admins.authenticate(email, password);

  if (!admin) {
    /* One message for every failure: never say which half was wrong. */
    return res.status(401).render("admin/login", {
      title: "Staff sign in",
      error: "Those details were not recognised."
    });
  }

  const secret = token();

  await admins.createSession(hash(secret), admin.id);

  res.cookie(ADMIN_COOKIE, secret, { ...COOKIE, maxAge: 12 * 3600_000 });
  res.redirect("/admin");
}

export async function logout(req, res) {
  const value = readCookie(req, ADMIN_COOKIE);

  if (value) await admins.deleteSession(hash(value));

  res.clearCookie(ADMIN_COOKIE, COOKIE);
  res.redirect("/admin/login");
}

export async function dashboard(req, res) {
  const [campaigns, advertisers, platform] = await Promise.all([
    ads.campaignReport(),
    listAdvertisers(),
    platformTotals()
  ]);

  res.set("Cache-Control", "no-store").render("admin/dashboard", {
    title: "Ad server",
    admin: req.admin,
    campaigns,
    advertisers,
    platform,
    notice: req.query.ok ?? null
  });
}

async function listAdvertisers() {
  const { rows } = await pool.query(
    "SELECT id, name, active FROM advertisers ORDER BY name"
  );

  return rows;
}

async function platformTotals() {
  const { rows } = await pool.query(`
    SELECT
      (SELECT count(*) FROM tenants WHERE billing_status = 'active')::int
        AS paying_tenants,
      (SELECT count(*) FROM subscribers WHERE state = 'active')::int
        AS recipients,
      (SELECT count(*) FROM stories WHERE issue_date = current_date)::int
        AS stories_today,
      (SELECT COALESCE(sum(impressions), 0) FROM campaigns)::int
        AS impressions,
      (SELECT COALESCE(sum(clicks), 0) FROM campaigns)::int AS clicks,
      (SELECT COALESCE(sum(round(impressions * cpm_cents / 1000.0)), 0)
       FROM campaigns)::int AS revenue_cents
  `);

  return rows[0];
}

const advertiserSchema = z.object({
  name: z.string().trim().min(1).max(120),
  contact_email: emailSchema.optional().or(z.literal("").transform(() => undefined))
});

export async function createAdvertiser(req, res) {
  const input = advertiserSchema.parse(req.body);

  await pool.query(
    "INSERT INTO advertisers(name, contact_email) VALUES($1,$2)",
    [input.name, input.contact_email ?? null]
  );

  res.redirect("/admin?ok=Advertiser+added");
}

/*
 * Targeting arrives as comma-separated text because that is what a form gives
 * you. Empty means "no restriction on this dimension", which is why blanks are
 * dropped rather than stored as an empty string that would match nothing.
 */
const list = value => String(value ?? "")
  .split(",")
  .map(entry => entry.trim())
  .filter(Boolean)
  .slice(0, 25);

const campaignSchema = z.object({
  advertiser_id: z.string().uuid(),
  name: z.string().trim().min(1).max(120),
  starts_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  ends_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  cpm_cents: z.coerce.number().int().min(0).max(1_000_000),
  daily_cap: z.coerce.number().int().min(0),
  total_cap: z.coerce.number().int().min(0)
});

export async function createCampaign(req, res) {
  const input = campaignSchema.parse(req.body);

  if (input.ends_on < input.starts_on) {
    throw new HttpError(400, "A campaign cannot end before it starts.");
  }

  const targeting = {
    titles: list(req.body?.titles),
    industries: list(req.body?.industries),
    topics: list(req.body?.topics)
  };

  await pool.query(
    `INSERT INTO campaigns(
       advertiser_id, name, status, starts_on, ends_on,
       cpm_cents, daily_cap, total_cap, targeting
     )
     VALUES($1,$2,'draft',$3,$4,$5,$6,$7,$8)`,
    [
      input.advertiser_id,
      input.name,
      input.starts_on,
      input.ends_on,
      input.cpm_cents,
      input.daily_cap,
      input.total_cap,
      JSON.stringify(targeting)
    ]
  );

  res.redirect("/admin?ok=Campaign+created+as+a+draft");
}

const creativeSchema = z.object({
  campaign_id: z.string().uuid(),
  slot: z.enum(["sponsored_story", "banner"]),
  headline: z.string().trim().min(1).max(200),
  body: z.string().trim().min(1).max(600),
  cta: z.string().trim().max(60).optional(),
  click_url: z.string().trim().url().max(2000)
});

export async function createCreative(req, res) {
  const input = creativeSchema.parse(req.body);

  /*
   * The click URL is stored only if it is http(s). The redirect checks again at
   * click time, but refusing it here means a bad creative never reaches an
   * issue in the first place.
   */
  if (!/^https?:\/\//i.test(input.click_url)) {
    throw new HttpError(400, "A click URL must start with http:// or https://");
  }

  await pool.query(
    `INSERT INTO creatives(campaign_id, slot, headline, body, cta, click_url)
     VALUES($1,$2,$3,$4,$5,$6)`,
    [
      input.campaign_id,
      input.slot,
      input.headline,
      input.body,
      input.cta || null,
      input.click_url
    ]
  );

  res.redirect("/admin?ok=Creative+added");
}

const STATUSES = ["draft", "active", "paused", "completed"];

export async function setCampaignStatus(req, res) {
  const status = String(req.body?.status ?? "");

  if (!STATUSES.includes(status)) {
    throw new HttpError(400, "Unknown campaign status.");
  }

  await pool.query(
    "UPDATE campaigns SET status = $2 WHERE id = $1",
    [req.params.id, status]
  );

  res.redirect(`/admin?ok=Campaign+${status}`);
}
