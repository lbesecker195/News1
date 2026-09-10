import path from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../.."
);

const read = (name, fallback = "") =>
  (process.env[name] ?? fallback).trim();

const integer = (name, fallback) => {
  const raw = read(name);
  const value = raw === "" ? fallback : Number(raw);

  if (!Number.isInteger(value)) {
    throw new Error(`${name} must be an integer.`);
  }

  return value;
};

/*
 * APP_ORIGIN is the canonical public origin. Everything user-visible — cookies,
 * login links, feed URLs, the same-origin check — is derived from it, so a
 * trailing slash or a stray path would leak into generated links.
 */
function origin(name, fallback) {
  const raw = read(name, fallback);

  let parsed;

  try {
    parsed = new URL(raw);
  } catch {
    throw new Error(`${name} must be an absolute URL, e.g. https://rnews1.com`);
  }

  if (!["http:", "https:"].includes(parsed.protocol)) {
    throw new Error(`${name} must use http:// or https://`);
  }

  return parsed.origin;
}

const digestHour = integer("DIGEST_HOUR", 13);

if (digestHour < 0 || digestHour > 23) {
  throw new Error("DIGEST_HOUR must be between 0 and 23.");
}

export const env = {
  appOrigin: origin("APP_ORIGIN", "http://localhost:3000"),
  databaseUrl: read("DATABASE_URL"),
  supportEmail: read("SUPPORT_EMAIL", "support@example.com"),

  /*
   * The sender's physical postal address. CAN-SPAM § 7704(a)(5)(A)(iii)
   * requires one in every commercial message, so the worker refuses to start
   * without it — a misconfiguration here is a per-message violation on every
   * issue sent, which is not something to discover later.
   */
  businessAddress: read("BUSINESS_ADDRESS"),
  port: integer("PORT", 3000),
  trustProxy: read("TRUST_PROXY") === "1",
  dataDir: path.resolve(ROOT, read("DATA_DIR", "./data")),

  /*
   * Shares the PayPal application with csuite_finder, so the variable names
   * match that project's exactly and one set of credentials serves both.
   */
  paypalMode: read("PAYPAL_MODE", "sandbox"),
  paypalBaseUrl: read("PAYPAL_BASE_URL") ||
    (read("PAYPAL_MODE") === "live"
      ? "https://api-m.paypal.com"
      : "https://api-m.sandbox.paypal.com"),
  paypalClientId: read("PAYPAL_CLIENT_ID"),
  paypalClientSecret: read("PAYPAL_CLIENT_SECRET"),
  paypalWebhookId: read("PAYPAL_WEBHOOK_ID"),

  mailgunApiKey: read("MAILGUN_API_KEY"),
  mailgunDomain: read("MAILGUN_DOMAIN"),
  mailgunFrom: read("MAILGUN_FROM"),
  mailgunSigningKey: read("MAILGUN_WEBHOOK_SIGNING_KEY"),
  mailgunApiBase: read("MAILGUN_API_BASE", "https://api.mailgun.net")
    .replace(/\/+$/, ""),

  /*
   * Extra hosts that serve our own published stories — custom domains on the
   * enterprise plan. Comma separated, host only. APP_ORIGIN is always included.
   */
  ownHosts: read("OWN_HOSTS")
    .split(",")
    .map(host => host.trim().toLowerCase())
    .filter(Boolean),

  /*
   * Story discovery runs through treg. Mint the worker its own identity rather
   * than reusing a personal token: treg org agent-new rnews1-worker
   */
  tregToken: read("TREG_TOKEN"),
  tregBaseUrl: read("TREG_BASE_URL", "https://treg.to").replace(/\/+$/, ""),

  /* exa (better news, $0.007) or serp (cheaper, $0.002). */
  newsProvider: read("NEWS_PROVIDER", "exa"),

  openaiApiKey: read("OPENAI_API_KEY"),
  openaiModel: read("OPENAI_MODEL", "gpt-5.6-luna"),

  digestHour
};

if (!["exa", "serp"].includes(env.newsProvider)) {
  throw new Error('NEWS_PROVIDER must be "exa" or "serp".');
}

export const pdfDir = path.join(env.dataDir, "pdfs");

const NAMES = {
  databaseUrl: "DATABASE_URL",
  supportEmail: "SUPPORT_EMAIL",
  businessAddress: "BUSINESS_ADDRESS",
  tregToken: "TREG_TOKEN",
  paypalClientId: "PAYPAL_CLIENT_ID",
  paypalClientSecret: "PAYPAL_CLIENT_SECRET",
  paypalWebhookId: "PAYPAL_WEBHOOK_ID",
  mailgunApiKey: "MAILGUN_API_KEY",
  mailgunDomain: "MAILGUN_DOMAIN",
  mailgunFrom: "MAILGUN_FROM",
  mailgunSigningKey: "MAILGUN_WEBHOOK_SIGNING_KEY",
  openaiApiKey: "OPENAI_API_KEY"
};

/*
 * Fail at boot rather than at the first request. The web process and the
 * worker need overlapping-but-different credentials, so each declares its own
 * list instead of validating everything everywhere.
 */
export function requireEnv(...keys) {
  const missing = keys.filter(key => !env[key]);

  if (missing.length) {
    throw new Error(
      `Missing required environment variables: ${
        missing.map(key => NAMES[key] ?? key).join(", ")
      }`
    );
  }
}

/*
 * PayPal is deliberately absent: like csuite_finder, the app runs without
 * payments configured so it can be developed and demoed, and /health reports
 * whether they are wired up.
 */
export const WEB_ENV = [
  "databaseUrl",
  "supportEmail",
  "mailgunSigningKey",
  "openaiApiKey"
];

export const WORKER_ENV = [
  "databaseUrl",
  "supportEmail",
  /* The worker is what sends, so it is what must not send without an address. */
  "businessAddress",
  /* And what discovers stories, so it is what needs the treg token. */
  "tregToken",
  "mailgunApiKey",
  "mailgunDomain",
  "mailgunFrom",
  "openaiApiKey"
];
