import { env } from "../config/env.mjs";

const TIMEOUT_MS = 20_000;

export class MailgunError extends Error {
  constructor(message, { status = 0, retryable = false } = {}) {
    super(message);
    this.name = "MailgunError";
    this.status = status;
    this.retryable = retryable;
  }
}

/*
 * Thrown when the request left this process but no answer came back. The
 * delivery loop must never retry these: Mailgun may well have accepted the
 * message, and a retry would send it twice. The webhook resolves the outcome.
 */
export class MailgunUnknownError extends MailgunError {
  constructor(message) {
    super(message, { retryable: false });
    this.name = "MailgunUnknownError";
  }
}

/*
 * jobId is attached as a Mailgun user variable so the events webhook can map
 * an event back to the outbox row that produced it.
 */
export async function sendEmail({
  to,
  subject,
  html,
  text,
  jobId = null,
  headers = {},
  tag = null
}) {
  const form = new FormData();

  form.set("from", env.mailgunFrom);
  form.set("to", to);
  form.set("subject", subject);

  if (text) form.set("text", text);
  if (html) form.set("html", html);
  if (jobId) form.set("v:job_id", jobId);
  if (tag) form.set("o:tag", tag);

  for (const [name, value] of Object.entries(headers)) {
    form.set(`h:${name}`, value);
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  let response;

  try {
    response = await fetch(
      `${env.mailgunApiBase}/v3/${env.mailgunDomain}/messages`,
      {
        method: "POST",
        signal: controller.signal,
        headers: {
          authorization: `Basic ${
            Buffer.from(`api:${env.mailgunApiKey}`).toString("base64")
          }`
        },
        body: form
      }
    );
  } catch (error) {
    throw new MailgunUnknownError(
      `Mailgun request did not complete: ${error.message}`
    );
  } finally {
    clearTimeout(timer);
  }

  const body = await response.text();

  if (response.ok) {
    let messageId = null;

    try {
      messageId = JSON.parse(body).id ?? null;
    } catch {
      /* A 200 without a parseable body still counts as accepted. */
    }

    return { messageId };
  }

  /*
   * 401/402/403 are credential or account problems, and 400 is a malformed
   * message: retrying either one just burns attempts. 429 and 5xx are worth
   * another pass.
   */
  throw new MailgunError(
    `Mailgun ${response.status}: ${body.replace(/\s+/g, " ").slice(0, 240)}`,
    {
      status: response.status,
      retryable: response.status === 429 || response.status >= 500
    }
  );
}

/*
 * Confirms the credentials actually reach Mailgun and that the domain is one
 * this key may send from.
 *
 * requireEnv only proves the variables are non-empty, which is how a
 * placeholder key gets all the way to a failed send. A worker that cannot
 * deliver should say so at boot, not queue mail nobody receives.
 */
export async function verifyMailgun() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const response = await fetch(
      `${env.mailgunApiBase}/v3/domains/${env.mailgunDomain}`,
      {
        signal: controller.signal,
        headers: {
          authorization: `Basic ${
            Buffer.from(`api:${env.mailgunApiKey}`).toString("base64")
          }`
        }
      }
    );

    if (response.status === 401) {
      throw new Error("Mailgun rejected the API key.");
    }

    if (response.status === 404) {
      throw new Error(
        `Mailgun does not have the domain ${env.mailgunDomain} on this account.`
      );
    }

    if (!response.ok) {
      throw new Error(`Mailgun returned ${response.status}.`);
    }

    const body = await response.json();

    return {
      domain: env.mailgunDomain,
      /* A sandbox domain only delivers to addresses authorised in Mailgun. */
      sandbox: /^sandbox/i.test(env.mailgunDomain),
      state: body?.domain?.state ?? "unknown"
    };
  } finally {
    clearTimeout(timer);
  }
}
