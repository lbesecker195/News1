import { env } from "./env.mjs";

/*
 * The PayPal REST client. Deliberately the same application as csuite_finder:
 * PAYPAL_CLIENT_ID / PAYPAL_CLIENT_SECRET / PAYPAL_WEBHOOK_ID name the same
 * credentials in both projects, so one PayPal app serves both.
 */

const TIMEOUT_MS = 30_000;

/* Refreshed a minute before it actually expires, to survive a slow request. */
const EXPIRY_MARGIN_MS = 60_000;

export class PayPalError extends Error {
  constructor(message, { status = 0, body = null, retryable = false } = {}) {
    super(message);
    this.name = "PayPalError";
    this.status = status;
    this.body = body;
    this.retryable = retryable;
  }
}

export const paypalConfigured = () =>
  Boolean(env.paypalClientId && env.paypalClientSecret);

let cachedToken = null;
let cachedUntil = 0;
let inFlight = null;

/*
 * Tokens last hours, so they are cached rather than minted per call. Concurrent
 * callers share one in-flight request instead of racing to mint several.
 */
export async function accessToken() {
  if (cachedToken && Date.now() < cachedUntil) return cachedToken;

  inFlight ??= mintToken().finally(() => {
    inFlight = null;
  });

  return inFlight;
}

async function mintToken() {
  if (!paypalConfigured()) {
    throw new PayPalError("PayPal is not configured.");
  }

  const auth = Buffer
    .from(`${env.paypalClientId}:${env.paypalClientSecret}`)
    .toString("base64");

  const response = await request("/v1/oauth2/token", {
    method: "POST",
    headers: {
      authorization: `Basic ${auth}`,
      "content-type": "application/x-www-form-urlencoded"
    },
    body: "grant_type=client_credentials"
  });

  if (response.status !== 200 || !response.body?.access_token) {
    throw new PayPalError(
      `PayPal authentication failed (${response.status})`,
      { status: response.status, body: response.body }
    );
  }

  cachedToken = response.body.access_token;
  cachedUntil = Date.now() +
    Math.max(0, Number(response.body.expires_in || 0) * 1000 - EXPIRY_MARGIN_MS);

  return cachedToken;
}

/* Only for tests and for a credential change at runtime. */
export function resetTokenCache() {
  cachedToken = null;
  cachedUntil = 0;
  inFlight = null;
}

async function request(path, init) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const response = await fetch(`${env.paypalBaseUrl}${path}`, {
      ...init,
      signal: controller.signal
    });

    const text = await response.text();

    let body = null;

    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      body = { raw: text.slice(0, 500) };
    }

    return { status: response.status, body };
  } catch (error) {
    throw new PayPalError(
      `PayPal request did not complete: ${error.message}`,
      { retryable: true }
    );
  } finally {
    clearTimeout(timer);
  }
}

/*
 * An authenticated call. A 401 means the cached token was revoked or rotated
 * out from under us, so it is dropped and the call retried exactly once.
 */
export async function paypal(method, path, body, { retryAuth = true } = {}) {
  const token = await accessToken();

  const response = await request(path, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { "content-type": "application/json" })
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  });

  if (response.status === 401 && retryAuth) {
    resetTokenCache();
    return paypal(method, path, body, { retryAuth: false });
  }

  return response;
}

export const ok = response => response.status >= 200 && response.status < 300;

/* Turns a non-2xx PayPal response into an error worth reading in a log. */
export function paypalError(action, response) {
  const detail = response.body?.message ||
    response.body?.details?.[0]?.description ||
    response.body?.error_description ||
    "";

  return new PayPalError(
    `PayPal ${action} failed (${response.status})${detail ? `: ${detail}` : ""}`,
    {
      status: response.status,
      body: response.body,
      retryable: response.status === 429 || response.status >= 500
    }
  );
}
