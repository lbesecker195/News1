Yes. The clean separation is:

- **Models:** Postgres queries and persistence.
- **Views:** EJS templates and browser assets.
- **Controllers:** HTTP input/output.
- **Services:** OpenAI, Mailgun, Stripe, crawling, PDF generation, and business workflows.
- **Workers:** Background scheduling and email delivery.

Below is a refactor of the application from the previous answer. The existing crawler, mailing worker, PDF generator, and contact importer are retained rather than rewritten.

---

# 1. Directory structure

```text
rnews1/
├── package.json
├── .env
├── .env.example
├── migrations/
│   └── 001_initial.sql
├── data/
│   └── pdfs/
├── public/
│   ├── app.js
│   └── site.css
├── scripts/
│   └── import-contacts.mjs
└── src/
    ├── app.mjs
    ├── server.mjs
    ├── config/
    │   ├── database.mjs
    │   └── stripe.mjs
    ├── controllers/
    │   ├── auth.controller.mjs
    │   ├── billing.controller.mjs
    │   ├── company.controller.mjs
    │   ├── feed.controller.mjs
    │   ├── site.controller.mjs
    │   ├── subscriber.controller.mjs
    │   └── webhook.controller.mjs
    ├── middleware/
    │   ├── auth.middleware.mjs
    │   ├── error.middleware.mjs
    │   ├── origin.middleware.mjs
    │   └── rate-limit.middleware.mjs
    ├── models/
    │   ├── auth.model.mjs
    │   ├── brief.model.mjs
    │   ├── company.model.mjs
    │   ├── mailgun-event.model.mjs
    │   └── subscriber.model.mjs
    ├── routes/
    │   ├── api.routes.mjs
    │   ├── site.routes.mjs
    │   └── webhook.routes.mjs
    ├── services/
    │   ├── billing.service.mjs
    │   ├── mailgun-webhook.service.mjs
    │   └── platform.service.mjs
    ├── utils/
    │   ├── async-handler.mjs
    │   ├── cookies.mjs
    │   ├── http-error.mjs
    │   └── validation.mjs
    ├── views/
    │   ├── partials/
    │   │   ├── header.ejs
    │   │   ├── footer.ejs
    │   │   └── news-item.ejs
    │   ├── auth/
    │   │   └── login.ejs
    │   ├── company/
    │   │   └── dashboard.ejs
    │   ├── feeds/
    │   │   ├── article.ejs
    │   │   ├── embed.ejs
    │   │   └── rss.ejs
    │   ├── marketing/
    │   │   └── home.ejs
    │   ├── legal/
    │   │   ├── privacy.ejs
    │   │   └── terms.ejs
    │   ├── subscribers/
    │   │   ├── confirm.ejs
    │   │   └── unsubscribe.ejs
    │   └── message.ejs
    └── workers/
        └── main.mjs
```

The request flow becomes:

```text
Route → Middleware → Controller → Service / Model → View or JSON
```

The background flow stays separate:

```text
Worker → Services / Database → Mailgun / OpenAI / PDFs
```

---

# 2. Move the existing files

From the previous implementation:

```bash
mkdir -p migrations scripts src/{config,controllers,middleware,models,routes,services,utils,workers}
mkdir -p src/views/{partials,auth,company,feeds,marketing,legal,subscribers}

mv schema.sql migrations/001_initial.sql
mv core.mjs src/services/platform.service.mjs
mv worker.mjs src/workers/main.mjs
mv import-contacts.mjs scripts/import-contacts.mjs

npm install ejs
```

Keep these files unchanged:

```text
public/app.js
public/site.css
.env
.env.example
```

Update the scripts in `package.json`:

```json
{
  "scripts": {
    "start": "node --env-file=.env src/server.mjs",
    "worker": "node --env-file=.env src/workers/main.mjs",
    "plan": "node --env-file=.env src/workers/main.mjs --plan",
    "import": "node --env-file=.env scripts/import-contacts.mjs"
  }
}
```

Keep the previous dependencies and add the installed `ejs` dependency.

---

# 3. Configuration and utilities

## `src/config/database.mjs`

Move database configuration and transaction handling out of the old `core.mjs`:

```javascript
import pg from "pg";

export const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10
});

export async function transaction(fn) {
  const client = await pool.connect();

  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
}
```

## `src/config/stripe.mjs`

```javascript
import Stripe from "stripe";

export const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

export async function validateStripePrice() {
  const price = await stripe.prices.retrieve(process.env.STRIPE_PRICE_ID);

  if (
    !price.active ||
    price.currency !== "usd" ||
    price.unit_amount !== 2500 ||
    price.recurring?.interval !== "month" ||
    price.recurring?.interval_count !== 1
  ) {
    throw new Error(
      "STRIPE_PRICE_ID must be an active recurring USD $25/month price."
    );
  }
}
```

## Update `src/services/platform.service.mjs`

This is your previous `core.mjs`.

Remove:

```javascript
import pg from "pg";
```

Remove its definitions of:

```javascript
export const pool = ...
export async function transaction(...) ...
```

Replace them with:

```javascript
import { pool, transaction } from "../config/database.mjs";

export { pool, transaction };
```

Keep its existing Mailgun, OpenAI, PDF, queue, escaping, and campaign-health functions.

This preserves compatibility with the worker while moving the database connection into configuration.

## `src/utils/async-handler.mjs`

```javascript
export const asyncHandler = fn => (req, res, next) =>
  Promise.resolve(fn(req, res, next)).catch(next);
```

## `src/utils/http-error.mjs`

```javascript
export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.name = "HttpError";
    this.status = status;
  }
}
```

## `src/utils/cookies.mjs`

```javascript
export function readCookie(req, name) {
  return (req.headers.cookie || "")
    .split(";")
    .map(value => value.trim())
    .find(value => value.startsWith(`${name}=`))
    ?.slice(name.length + 1);
}
```

## `src/utils/validation.mjs`

```javascript
import { z } from "zod";

export const isUUID = value =>
  z.string().uuid().safeParse(value).success;

export const isLoginToken = value =>
  typeof value === "string" &&
  /^[A-Za-z0-9_-]{43}$/.test(value);

export const emailSchema = z.string()
  .trim()
  .email()
  .max(254)
  .transform(value => value.toLowerCase());

export const companySchema = z.object({
  name: z.string().trim().min(1).max(100),
  domain: z.string().trim().min(1).max(253),
  industry: z.string().trim().min(1).max(100),
  keywords: z.array(
    z.string().trim().min(1).max(60)
  ).max(10),
  language: z.enum(["en", "es", "fr", "de"])
});

export const suggestionInputSchema = z.object({
  name: z.string().max(100),
  domain: z.string().max(253),
  industry: z.string().max(100)
});

export const suggestionResultSchema = z.object({
  industry: z.string().max(100),
  keywords: z.array(
    z.string().min(1).max(60)
  ).min(3).max(6)
});

export const invitationSchema = z.object({
  email: emailSchema,
  permission: z.literal(true)
});
```

---

# 4. Models

Models contain database operations, not Express request/response handling.

## `src/models/auth.model.mjs`

```javascript
import { pool, transaction } from "../config/database.mjs";

export async function createLogin({ email, tokenHash, url }) {
  return transaction(async db => {
    const { rows } = await db.query(
      `INSERT INTO tenants(owner_email)
       VALUES($1)
       ON CONFLICT(owner_email)
       DO UPDATE SET owner_email=EXCLUDED.owner_email
       RETURNING id`,
      [email]
    );

    const tenantId = rows[0].id;

    await db.query(
      `INSERT INTO login_tokens(hash,tenant_id,expires_at)
       VALUES($1,$2,now()+interval '20 minutes')`,
      [tokenHash, tenantId]
    );

    await db.query(
      `INSERT INTO outbox(
         tenant_id,to_email,kind,payload,expires_at
       )
       VALUES($1,$2,'login',$3,now()+interval '20 minutes')`,
      [tenantId, email, JSON.stringify({ url })]
    );

    return tenantId;
  });
}

export async function consumeLoginAndCreateSession({
  loginHash,
  sessionHash
}) {
  return transaction(async db => {
    const { rows } = await db.query(
      `DELETE FROM login_tokens
       WHERE hash=$1 AND expires_at>now()
       RETURNING tenant_id`,
      [loginHash]
    );

    if (!rows[0]) return null;

    await db.query(
      `INSERT INTO sessions(hash,tenant_id,expires_at)
       VALUES($1,$2,now()+interval '14 days')`,
      [sessionHash, rows[0].tenant_id]
    );

    return rows[0].tenant_id;
  });
}

export async function findTenantBySession(sessionHash) {
  const { rows } = await pool.query(
    `SELECT t.*
     FROM sessions s
     JOIN tenants t ON t.id=s.tenant_id
     WHERE s.hash=$1 AND s.expires_at>now()`,
    [sessionHash]
  );

  return rows[0] || null;
}

export async function deleteSession(sessionHash) {
  await pool.query(
    "DELETE FROM sessions WHERE hash=$1",
    [sessionHash]
  );
}
```

## `src/models/company.model.mjs`

```javascript
import { pool, transaction } from "../config/database.mjs";

export async function saveSettings(tenantId, input, topic) {
  await transaction(async db => {
    await db.query(
      `INSERT INTO topics(key,query,language)
       VALUES($1,$2,$3)
       ON CONFLICT DO NOTHING`,
      [topic.key, topic.query, input.language]
    );

    await db.query(
      `UPDATE tenants SET
         name=$1,
         domain=$2,
         industry=$3,
         keywords=$4,
         language=$5,
         topic_key=$6
       WHERE id=$7`,
      [
        input.name,
        input.domain,
        input.industry,
        JSON.stringify(input.keywords),
        input.language,
        topic.key,
        tenantId
      ]
    );
  });
}

export async function findPreview(topicKey) {
  const { rows } = await pool.query(
    `SELECT items,refreshed_at
     FROM topics WHERE key=$1`,
    [topicKey]
  );

  return rows[0] || {
    items: [],
    refreshed_at: null
  };
}

export async function findPublicTenant(publicToken) {
  const { rows } = await pool.query(
    `SELECT t.*,p.items,p.refreshed_at
     FROM tenants t
     JOIN topics p ON p.key=t.topic_key
     WHERE t.public_token=$1
       AND t.billing_status='active'`,
    [publicToken]
  );

  return rows[0] || null;
}

export async function withBillingLock(tenantId, fn) {
  return transaction(async db => {
    const { rows } = await db.query(
      "SELECT * FROM tenants WHERE id=$1 FOR UPDATE",
      [tenantId]
    );

    return fn(rows[0], db);
  });
}

export async function setCustomer(db, tenantId, customerId) {
  await db.query(
    `UPDATE tenants SET stripe_customer=$1 WHERE id=$2`,
    [customerId, tenantId]
  );
}

export async function setCheckout(db, tenantId, checkoutId) {
  await db.query(
    `UPDATE tenants SET checkout_id=$1 WHERE id=$2`,
    [checkoutId, tenantId]
  );
}

export async function syncSubscription({
  tenantId,
  subscriptionId,
  customerId,
  status
}) {
  await pool.query(
    `UPDATE tenants SET
       subscription_id=$1,
       billing_status=$2,
       stripe_customer=$3
     WHERE id=$4
       AND (stripe_customer IS NULL OR stripe_customer=$3)`,
    [subscriptionId, status, customerId, tenantId]
  );
}
```

## `src/models/subscriber.model.mjs`

```javascript
import { pool, transaction } from "../config/database.mjs";
import { HttpError } from "../utils/http-error.mjs";

export async function listForTenant(tenantId) {
  const { rows } = await pool.query(
    `SELECT c.email,s.state
     FROM subscribers s
     JOIN contacts c ON c.id=s.contact_id
     WHERE s.tenant_id=$1
     ORDER BY c.email`,
    [tenantId]
  );

  return rows;
}

export async function createInvitation({
  tenantId,
  email,
  appOrigin
}) {
  return transaction(async db => {
    const tenantResult = await db.query(
      "SELECT * FROM tenants WHERE id=$1 FOR UPDATE",
      [tenantId]
    );

    const tenant = tenantResult.rows[0];

    if (!tenant || tenant.billing_status !== "active") {
      throw new HttpError(402, "Activate your subscription first.");
    }

    const count = await db.query(
      `SELECT count(*)::int AS n
       FROM subscribers WHERE tenant_id=$1`,
      [tenantId]
    );

    if (count.rows[0].n >= 10) {
      throw new HttpError(409, "The plan allows 10 recipients.");
    }

    const contactResult = await db.query(
      `INSERT INTO contacts(email)
       VALUES($1)
       ON CONFLICT(email)
       DO UPDATE SET email=EXCLUDED.email
       RETURNING *`,
      [email]
    );

    const contact = contactResult.rows[0];

    if (contact.opted_out_at || contact.bounced_at) {
      throw new HttpError(
        409,
        "This address is suppressed. Contact support to review."
      );
    }

    const invitation = await db.query(
      `INSERT INTO subscribers(tenant_id,contact_id)
       VALUES($1,$2)
       ON CONFLICT DO NOTHING
       RETURNING confirm_token`,
      [tenantId, contact.id]
    );

    if (!invitation.rows[0]) {
      throw new HttpError(409, "This recipient is already listed.");
    }

    const payload = {
      company: tenant.name,
      url: `${appOrigin}/confirm/${invitation.rows[0].confirm_token}`
    };

    await db.query(
      `INSERT INTO outbox(
         tenant_id,contact_id,to_email,kind,payload,expires_at
       )
       VALUES($1,$2,$3,'confirmation',$4,now()+interval '7 days')`,
      [tenantId, contact.id, email, JSON.stringify(payload)]
    );
  });
}

export async function remove(tenantId, email) {
  await pool.query(
    `DELETE FROM subscribers s
     USING contacts c
     WHERE s.contact_id=c.id
       AND s.tenant_id=$1
       AND c.email=$2`,
    [tenantId, email]
  );
}

export async function confirm(confirmToken) {
  const result = await pool.query(
    `UPDATE subscribers s
     SET state='active',confirmed_at=now()
     FROM contacts c
     WHERE s.contact_id=c.id
       AND s.confirm_token=$1
       AND s.confirm_expires_at>now()
       AND c.opted_out_at IS NULL
       AND c.bounced_at IS NULL
     RETURNING s.tenant_id`,
    [confirmToken]
  );

  return result.rowCount > 0;
}

export async function unsubscribe(unsubscribeToken) {
  await transaction(async db => {
    const result = await db.query(
      `UPDATE contacts
       SET opted_out_at=COALESCE(opted_out_at,now())
       WHERE unsub_token=$1
       RETURNING id`,
      [unsubscribeToken]
    );

    if (!result.rows[0]) return;

    await db.query(
      `UPDATE outbox SET status='suppressed'
       WHERE contact_id=$1
         AND status='pending'
         AND kind<>'login'`,
      [result.rows[0].id]
    );
  });
}
```

## `src/models/brief.model.mjs`

```javascript
import { pool } from "../config/database.mjs";

export async function findUnexpired(id) {
  const { rows } = await pool.query(
    `SELECT id,html
     FROM briefs
     WHERE id=$1 AND expires_at>now()`,
    [id]
  );

  return rows[0] || null;
}
```

## `src/models/mailgun-event.model.mjs`

```javascript
import { transaction } from "../config/database.mjs";

export async function recordAndApply({
  id,
  kind,
  jobId,
  email
}) {
  await transaction(async db => {
    const inserted = await db.query(
      `INSERT INTO mailgun_events(id,kind,job_id)
       VALUES($1,$2,$3)
       ON CONFLICT DO NOTHING
       RETURNING id`,
      [id, kind, jobId]
    );

    if (!inserted.rowCount) return;

    if (jobId && ["accepted", "delivered"].includes(kind)) {
      await db.query(
        `UPDATE outbox SET status='accepted'
         WHERE id=$1
           AND status IN ('processing','unknown','pending')`,
        [jobId]
      );
    }

    if (["complained", "unsubscribed"].includes(kind)) {
      await db.query(
        `UPDATE contacts
         SET opted_out_at=COALESCE(opted_out_at,now())
         WHERE email=$1`,
        [email]
      );
    }

    if (kind === "hard_bounce") {
      await db.query(
        `UPDATE contacts
         SET bounced_at=COALESCE(bounced_at,now())
         WHERE email=$1`,
        [email]
      );
    }
  });
}
```

---

# 5. Services

Services contain external integrations and business logic.

## `src/services/billing.service.mjs`

```javascript
import { stripe } from "../config/stripe.mjs";
import * as companies from "../models/company.model.mjs";
import { APP } from "./platform.service.mjs";
import { HttpError } from "../utils/http-error.mjs";
import { isUUID } from "../utils/validation.mjs";

export async function createPortal(customerId) {
  if (!customerId) {
    throw new HttpError(400, "No billing account yet.");
  }

  const session = await stripe.billingPortal.sessions.create({
    customer: customerId,
    return_url: `${APP}/app`
  });

  return session.url;
}

export async function createCheckout(tenantId) {
  return companies.withBillingLock(tenantId, async (tenant, db) => {
    if (!tenant?.topic_key || !tenant.domain) {
      throw new HttpError(
        400,
        "Save your company settings first."
      );
    }

    let customer = tenant.stripe_customer;

    if (!customer) {
      const created = await stripe.customers.create({
        email: tenant.owner_email,
        name: tenant.name,
        metadata: { tenantId: tenant.id }
      }, {
        idempotencyKey: `customer:${tenant.id}`
      });

      customer = created.id;
      await companies.setCustomer(db, tenant.id, customer);
    }

    const subscriptions = await stripe.subscriptions.list({
      customer,
      status: "all",
      limit: 100
    });

    const existingSubscription = subscriptions.data.some(
      subscription => ![
        "canceled",
        "incomplete_expired"
      ].includes(subscription.status)
    );

    if (existingSubscription) {
      return createPortal(customer);
    }

    if (tenant.checkout_id) {
      const existing = await stripe.checkout.sessions.retrieve(
        tenant.checkout_id
      );

      if (
        existing.status === "open" &&
        existing.expires_at * 1000 > Date.now()
      ) {
        return existing.url;
      }
    }

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer,
      line_items: [{
        price: process.env.STRIPE_PRICE_ID,
        quantity: 1
      }],
      subscription_data: {
        metadata: { tenantId: tenant.id }
      },
      metadata: { tenantId: tenant.id },
      success_url: `${APP}/app?checkout=success`,
      cancel_url: `${APP}/app?checkout=canceled`,
      allow_promotion_codes: false
    });

    await companies.setCheckout(db, tenant.id, session.id);
    return session.url;
  });
}

export async function processStripeEvent(event) {
  let subscriptionId;

  if (event.type === "checkout.session.completed") {
    subscriptionId = event.data.object.subscription;
  } else if (event.type.startsWith("customer.subscription.")) {
    subscriptionId = event.data.object.id;
  }

  if (!subscriptionId) return;

  const subscription = await stripe.subscriptions.retrieve(
    typeof subscriptionId === "string"
      ? subscriptionId
      : subscriptionId.id
  );

  const tenantId = subscription.metadata.tenantId;
  if (!isUUID(tenantId)) return;

  const expectedPrice = subscription.items.data.some(
    item => item.price.id === process.env.STRIPE_PRICE_ID
  );

  const customerId = typeof subscription.customer === "string"
    ? subscription.customer
    : subscription.customer.id;

  await companies.syncSubscription({
    tenantId,
    subscriptionId: subscription.id,
    customerId,
    status: expectedPrice
      ? subscription.status
      : "invalid_price"
  });
}
```

## `src/services/mailgun-webhook.service.mjs`

```javascript
import crypto from "node:crypto";
import * as events from "../models/mailgun-event.model.mjs";
import { HttpError } from "../utils/http-error.mjs";
import { isUUID } from "../utils/validation.mjs";

export async function processMailgunWebhook(body) {
  const signature = body.signature || {};

  const timestamp = String(signature.timestamp || "");
  const signingToken = String(signature.token || "");
  const supplied = String(signature.signature || "");

  if (
    !/^\d+$/.test(timestamp) ||
    Math.abs(Date.now() / 1000 - Number(timestamp)) > 86400 ||
    !/^[a-f0-9]{64}$/i.test(supplied)
  ) {
    throw new HttpError(403, "Invalid Mailgun signature.");
  }

  const expected = crypto.createHmac(
    "sha256",
    process.env.MAILGUN_WEBHOOK_SIGNING_KEY
  )
    .update(timestamp + signingToken)
    .digest("hex");

  if (!crypto.timingSafeEqual(
    Buffer.from(expected, "hex"),
    Buffer.from(supplied, "hex")
  )) {
    throw new HttpError(403, "Invalid Mailgun signature.");
  }

  const data = body["event-data"];

  if (!data?.id || !data?.event) {
    throw new HttpError(400, "Invalid Mailgun event.");
  }

  const candidateJobId = data["user-variables"]?.job_id;

  const kind = data.event === "failed" &&
    data.severity === "permanent"
    ? "hard_bounce"
    : data.event;

  await events.recordAndApply({
    id: String(data.id),
    kind,
    jobId: isUUID(candidateJobId) ? candidateJobId : null,
    email: String(data.recipient || "").trim().toLowerCase()
  });
}
```

---

# 6. Middleware

## `src/middleware/auth.middleware.mjs`

```javascript
import * as auth from "../models/auth.model.mjs";
import { hash } from "../services/platform.service.mjs";
import { readCookie } from "../utils/cookies.mjs";

export async function requireAuth(req, res, next) {
  try {
    const value = readCookie(req, "session");

    const tenant = value
      ? await auth.findTenantBySession(hash(value))
      : null;

    if (!tenant) {
      if (req.path === "/app") {
        return res.redirect("/");
      }

      return res.status(401).json({
        error: "Sign in first."
      });
    }

    req.tenant = tenant;
    next();
  } catch (error) {
    next(error);
  }
}
```

## `src/middleware/origin.middleware.mjs`

```javascript
import { APP } from "../services/platform.service.mjs";

export function requireSameOrigin(req, res, next) {
  if (req.get("origin") !== APP) {
    return res.status(403).json({
      error: "Invalid request origin."
    });
  }

  next();
}

export function protectMutations(req, res, next) {
  if (["GET", "HEAD", "OPTIONS"].includes(req.method)) {
    return next();
  }

  return requireSameOrigin(req, res, next);
}
```

## `src/middleware/rate-limit.middleware.mjs`

```javascript
import { rateLimit } from "express-rate-limit";

function limiter(windowMs, limit) {
  return rateLimit({
    windowMs,
    limit,
    standardHeaders: "draft-7",
    legacyHeaders: false
  });
}

export const loginLimiter = limiter(60 * 60 * 1000, 5);
export const apiLimiter = limiter(60 * 1000, 60);
export const inviteLimiter = limiter(60 * 60 * 1000, 20);
```

For multiple Express instances, replace the default in-memory limiter store with a shared store.

## `src/middleware/error.middleware.mjs`

```javascript
import { ZodError } from "zod";
import { HttpError } from "../utils/http-error.mjs";

export function notFound(req, res) {
  if (
    req.path.startsWith("/api/") ||
    req.path.startsWith("/webhooks/")
  ) {
    return res.status(404).json({ error: "Not found." });
  }

  return res.status(404).render("message", {
    title: "Not found",
    heading: "Page not found",
    message: "The requested page is unavailable."
  });
}

export function errorHandler(error, req, res, next) {
  if (res.headersSent) return next(error);

  const status = error instanceof ZodError
    ? 400
    : error instanceof HttpError
      ? error.status
      : 500;

  const message = error instanceof ZodError
    ? "Invalid input."
    : error instanceof HttpError
      ? error.message
      : "Request failed. Please try again or contact support.";

  if (status >= 500) {
    console.error(error);
  }

  if (
    req.path.startsWith("/api/") ||
    req.path.startsWith("/webhooks/")
  ) {
    return res.status(status).json({ error: message });
  }

  return res.status(status).render("message", {
    title: "Request failed",
    heading: "We couldn't complete that request",
    message
  });
}
```

---

# 7. Controllers

## `src/controllers/auth.controller.mjs`

```javascript
import * as auth from "../models/auth.model.mjs";
import {
  APP,
  token,
  hash
} from "../services/platform.service.mjs";

import { readCookie } from "../utils/cookies.mjs";
import { HttpError } from "../utils/http-error.mjs";
import {
  emailSchema,
  isLoginToken
} from "../utils/validation.mjs";

export async function requestLogin(req, res) {
  const email = emailSchema.parse(req.body.email);
  const secret = token();

  await auth.createLogin({
    email,
    tokenHash: hash(secret),
    url: `${APP}/login/${secret}`
  });

  res.json({
    message: "Check your email for a sign-in link."
  });
}

export function showLogin(req, res) {
  if (!isLoginToken(req.params.token)) {
    throw new HttpError(400, "Invalid sign-in link.");
  }

  res.set("Cache-Control", "no-store").render("auth/login", {
    title: "Confirm sign in",
    loginToken: req.params.token
  });
}

export async function completeLogin(req, res) {
  if (!isLoginToken(req.params.token)) {
    throw new HttpError(400, "Invalid sign-in link.");
  }

  const sessionSecret = token();

  const tenantId = await auth.consumeLoginAndCreateSession({
    loginHash: hash(req.params.token),
    sessionHash: hash(sessionSecret)
  });

  if (!tenantId) {
    throw new HttpError(400, "Link expired or already used.");
  }

  res.cookie("session", sessionSecret, {
    httpOnly: true,
    secure: APP.startsWith("https://"),
    sameSite: "lax",
    path: "/",
    maxAge: 14 * 86400000
  });

  res.redirect("/app");
}

export async function logout(req, res) {
  await auth.deleteSession(
    hash(readCookie(req, "session") || "")
  );

  res.clearCookie("session", { path: "/" });
  res.json({ ok: true });
}
```

## `src/controllers/company.controller.mjs`

```javascript
import * as companies from "../models/company.model.mjs";
import * as subscribers from "../models/subscriber.model.mjs";

import {
  APP,
  aiJSON,
  hash,
  companyDomain
} from "../services/platform.service.mjs";

import {
  companySchema,
  suggestionInputSchema,
  suggestionResultSchema
} from "../utils/validation.mjs";

import { HttpError } from "../utils/http-error.mjs";

export async function me(req, res) {
  const tenant = req.tenant;

  res.set("Cache-Control", "no-store").json({
    tenant: {
      name: tenant.name,
      domain: tenant.domain,
      industry: tenant.industry,
      keywords: tenant.keywords,
      language: tenant.language,
      billing_status: tenant.billing_status
    },
    subscribers: await subscribers.listForTenant(tenant.id),
    rss: `${APP}/feed/${tenant.public_token}.xml`,
    embed: `${APP}/embed/${tenant.public_token}`
  });
}

export async function save(req, res) {
  const input = companySchema.parse(req.body);

  try {
    input.domain = companyDomain(input.domain);
  } catch {
    throw new HttpError(400, "Enter a valid company domain.");
  }

  const terms = [
    ...new Set([input.industry, ...input.keywords])
  ];

  const query = terms
    .map(value => `"${value.replace(/["\\]/g, "")}"`)
    .join(" OR ");

  const topic = {
    query,
    key: hash(`${input.language}:${query}`)
  };

  await companies.saveSettings(req.tenant.id, input, topic);

  res.json({
    message: "Saved. The worker will prepare your preview shortly."
  });
}

export async function suggest(req, res) {
  const input = suggestionInputSchema.parse(req.body);

  const output = await aiJSON(
    `Suggest a news industry label and 3-6 keywords.
Do not claim you visited the website.
Domain and company name may be ambiguous.
These are suggestions for the user to confirm.
Return {"industry":"...","keywords":["..."]}.`,
    input
  );

  res.json(suggestionResultSchema.parse(output));
}

export async function preview(req, res) {
  const data = await companies.findPreview(req.tenant.topic_key);

  res.json({
    ...data,
    items: data.items.slice(0, 8)
  });
}
```

## `src/controllers/subscriber.controller.mjs`

```javascript
import * as subscribers from "../models/subscriber.model.mjs";
import { APP } from "../services/platform.service.mjs";
import { HttpError } from "../utils/http-error.mjs";

import {
  emailSchema,
  invitationSchema,
  isUUID
} from "../utils/validation.mjs";

export async function invite(req, res) {
  const input = invitationSchema.parse(req.body);

  await subscribers.createInvitation({
    tenantId: req.tenant.id,
    email: input.email,
    appOrigin: APP
  });

  res.json({
    message: "Confirmation invitation queued."
  });
}

export async function remove(req, res) {
  await subscribers.remove(
    req.tenant.id,
    emailSchema.parse(req.body.email)
  );

  res.json({ ok: true });
}

export function showConfirmation(req, res) {
  if (!isUUID(req.params.token)) {
    throw new HttpError(400, "Invalid invitation.");
  }

  res.render("subscribers/confirm", {
    title: "Confirm subscription",
    confirmationToken: req.params.token
  });
}

export async function confirm(req, res) {
  if (!isUUID(req.params.token)) {
    throw new HttpError(400, "Invalid invitation.");
  }

  const confirmed = await subscribers.confirm(req.params.token);

  res.status(confirmed ? 200 : 400).render("message", {
    title: "Subscription",
    heading: confirmed
      ? "You're subscribed."
      : "This invitation is no longer valid.",
    message: confirmed
      ? "Your company briefing will arrive by email."
      : "Ask your account administrator for help."
  });
}

export function showUnsubscribe(req, res) {
  if (!isUUID(req.params.token)) {
    throw new HttpError(400, "Invalid unsubscribe link.");
  }

  res.render("subscribers/unsubscribe", {
    title: "Unsubscribe",
    unsubscribeToken: req.params.token
  });
}

export async function unsubscribe(req, res) {
  if (!isUUID(req.params.token)) {
    throw new HttpError(400, "Invalid unsubscribe link.");
  }

  await subscribers.unsubscribe(req.params.token);

  res.render("message", {
    title: "Unsubscribed",
    heading: "You have been unsubscribed.",
    message: "Marketing and digest emails have been stopped for this address."
  });
}
```

## `src/controllers/billing.controller.mjs`

```javascript
import * as billing from "../services/billing.service.mjs";

export async function checkout(req, res) {
  const url = await billing.createCheckout(req.tenant.id);
  res.json({ url });
}

export async function portal(req, res) {
  const url = await billing.createPortal(
    req.tenant.stripe_customer
  );

  res.json({ url });
}
```

## `src/controllers/feed.controller.mjs`

```javascript
import path from "node:path";

import * as companies from "../models/company.model.mjs";
import * as briefs from "../models/brief.model.mjs";

import {
  APP,
  safeURL
} from "../services/platform.service.mjs";

import { HttpError } from "../utils/http-error.mjs";
import { isUUID } from "../utils/validation.mjs";

async function requirePublicTenant(token) {
  if (!isUUID(token)) {
    throw new HttpError(404, "Feed not found.");
  }

  const tenant = await companies.findPublicTenant(token);

  if (!tenant) {
    throw new HttpError(404, "Feed not found.");
  }

  return tenant;
}

function presentItem(tenant, item) {
  return {
    ...item,
    sourceUrl: safeURL(item.url),
    hostedUrl: `${APP}/news/${tenant.public_token}/${item.id}`
  };
}

export async function rss(req, res) {
  const tenant = await requirePublicTenant(req.params.token);

  const items = tenant.items
    .slice(0, 8)
    .map(item => ({
      ...presentItem(tenant, item),
      pubDate: new Date(item.published).toUTCString()
    }));

  res.type("application/rss+xml").render("feeds/rss", {
    tenant,
    items
  });
}

export async function embed(req, res) {
  const tenant = await requirePublicTenant(req.params.token);

  res.removeHeader("X-Frame-Options");
  res.set(
    "Content-Security-Policy",
    "default-src 'none'; style-src 'self'; frame-ancestors *; base-uri 'none'"
  );

  res.render("feeds/embed", {
    title: `${tenant.name} news`,
    tenant,
    items: tenant.items
      .slice(0, 8)
      .map(item => presentItem(tenant, item))
  });
}

export async function article(req, res) {
  const tenant = await requirePublicTenant(req.params.token);

  const item = tenant.items.find(
    candidate => candidate.id === req.params.id
  );

  if (!item) {
    throw new HttpError(404, "Article not found.");
  }

  res.render("feeds/article", {
    title: item.title,
    tenant,
    item: presentItem(tenant, item)
  });
}

export async function brief(req, res) {
  if (!isUUID(req.params.id)) {
    throw new HttpError(404, "Brief not found.");
  }

  const brief = await briefs.findUnexpired(req.params.id);

  if (!brief) {
    throw new HttpError(404, "Brief not found.");
  }

  // This is a pre-rendered document generated by the background service.
  res.set("Cache-Control", "private, no-store").send(brief.html);
}

export async function pdf(req, res) {
  if (!isUUID(req.params.id)) {
    throw new HttpError(404, "PDF not found.");
  }

  const brief = await briefs.findUnexpired(req.params.id);

  if (!brief) {
    throw new HttpError(404, "PDF not found.");
  }

  res.set("Cache-Control", "private, no-store");
  res.download(
    path.resolve(`./data/pdfs/${brief.id}.pdf`),
    "company-news-brief.pdf"
  );
}
```

## `src/controllers/webhook.controller.mjs`

```javascript
import { stripe } from "../config/stripe.mjs";

import { processStripeEvent } from "../services/billing.service.mjs";
import { processMailgunWebhook } from "../services/mailgun-webhook.service.mjs";

export async function stripeWebhook(req, res) {
  let event;

  try {
    event = stripe.webhooks.constructEvent(
      req.body,
      req.headers["stripe-signature"],
      process.env.STRIPE_WEBHOOK_SECRET
    );
  } catch {
    return res.status(400).json({
      error: "Invalid Stripe signature."
    });
  }

  await processStripeEvent(event);
  res.json({ received: true });
}

export async function mailgunWebhook(req, res) {
  await processMailgunWebhook(req.body);
  res.sendStatus(200);
}
```

## `src/controllers/site.controller.mjs`

```javascript
import { pool } from "../config/database.mjs";

export function home(req, res) {
  res.render("marketing/home", {
    title: "Your industry. One useful daily briefing.",
    indexable: true
  });
}

export function dashboard(req, res) {
  res.set("Cache-Control", "no-store").render("company/dashboard", {
    title: "Company dashboard"
  });
}

export function privacy(req, res) {
  res.render("legal/privacy", { title: "Privacy" });
}

export function terms(req, res) {
  res.render("legal/terms", { title: "Terms" });
}

export async function health(req, res) {
  await pool.query("SELECT 1");
  res.json({ ok: true });
}
```

The health check is an infrastructure probe, so it does not need an application entity model.

---

# 8. Routes

## `src/routes/api.routes.mjs`

```javascript
import { Router } from "express";

import * as auth from "../controllers/auth.controller.mjs";
import * as company from "../controllers/company.controller.mjs";
import * as subscriber from "../controllers/subscriber.controller.mjs";
import * as billing from "../controllers/billing.controller.mjs";

import { asyncHandler as wrap } from "../utils/async-handler.mjs";
import { requireAuth } from "../middleware/auth.middleware.mjs";
import { protectMutations } from "../middleware/origin.middleware.mjs";

import {
  apiLimiter,
  loginLimiter,
  inviteLimiter
} from "../middleware/rate-limit.middleware.mjs";

export const apiRoutes = Router();

apiRoutes.use(apiLimiter);
apiRoutes.use(protectMutations);

// Public authentication endpoint.
apiRoutes.post("/login", loginLimiter, wrap(auth.requestLogin));

// Everything below requires a valid session.
apiRoutes.use(requireAuth);

apiRoutes.post("/logout", wrap(auth.logout));

apiRoutes.get("/me", wrap(company.me));
apiRoutes.post("/company", wrap(company.save));
apiRoutes.post("/suggest", wrap(company.suggest));
apiRoutes.get("/preview", wrap(company.preview));

apiRoutes.post(
  "/subscribers",
  inviteLimiter,
  wrap(subscriber.invite)
);
apiRoutes.delete("/subscribers", wrap(subscriber.remove));

apiRoutes.post("/checkout", wrap(billing.checkout));
apiRoutes.post("/portal", wrap(billing.portal));
```

## `src/routes/site.routes.mjs`

```javascript
import { Router } from "express";

import * as site from "../controllers/site.controller.mjs";
import * as auth from "../controllers/auth.controller.mjs";
import * as subscriber from "../controllers/subscriber.controller.mjs";
import * as feed from "../controllers/feed.controller.mjs";

import { asyncHandler as wrap } from "../utils/async-handler.mjs";
import { requireAuth } from "../middleware/auth.middleware.mjs";
import { requireSameOrigin } from "../middleware/origin.middleware.mjs";

export const siteRoutes = Router();

siteRoutes.get("/", site.home);
siteRoutes.get("/app", requireAuth, site.dashboard);

siteRoutes.get("/privacy", site.privacy);
siteRoutes.get("/terms", site.terms);
siteRoutes.get("/health", wrap(site.health));

siteRoutes.get("/login/:token", wrap(auth.showLogin));
siteRoutes.post(
  "/login/:token",
  requireSameOrigin,
  wrap(auth.completeLogin)
);

siteRoutes.get(
  "/confirm/:token",
  wrap(subscriber.showConfirmation)
);
siteRoutes.post(
  "/confirm/:token",
  requireSameOrigin,
  wrap(subscriber.confirm)
);

siteRoutes.get("/u/:token", wrap(subscriber.showUnsubscribe));

// Intentionally no origin guard: supports Mailgun/mail-client one-click POST.
siteRoutes.post("/u/:token", wrap(subscriber.unsubscribe));

siteRoutes.get("/feed/:token.xml", wrap(feed.rss));
siteRoutes.get("/embed/:token", wrap(feed.embed));
siteRoutes.get("/news/:token/:id", wrap(feed.article));

siteRoutes.get("/brief/:id", wrap(feed.brief));
siteRoutes.get("/pdf/:id", wrap(feed.pdf));
```

## `src/routes/webhook.routes.mjs`

```javascript
import express, { Router } from "express";

import * as webhook from "../controllers/webhook.controller.mjs";
import { asyncHandler as wrap } from "../utils/async-handler.mjs";

export const stripeWebhookRoutes = Router();
export const mailgunWebhookRoutes = Router();

stripeWebhookRoutes.post(
  "/",
  express.raw({
    type: "application/json",
    limit: "1mb"
  }),
  wrap(webhook.stripeWebhook)
);

mailgunWebhookRoutes.post(
  "/",
  wrap(webhook.mailgunWebhook)
);
```

---

# 9. Views

All request-rendered HTML now lives under `src/views`.

EJS escapes values rendered with `<%= ... %>`. Use `<%- ... %>` only for trusted template includes.

## `src/views/partials/header.ejs`

```ejs
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">

  <% if (indexable) { %>
    <meta
      name="description"
      content="Company news feeds, website embeds and daily team briefings for $25/month."
    >
  <% } else { %>
    <meta name="robots" content="noindex">
  <% } %>

  <title><%= title %> — Rnews1</title>
  <link rel="stylesheet" href="/site.css">
</head>
<body>
  <nav>
    <a href="/">
      rnews1<span> / business intelligence</span>
    </a>
  </nav>
  <main>
```

## `src/views/partials/footer.ejs`

```ejs
  </main>

  <footer>
    <a href="/">Powered by Rnews1</a> ·
    <a href="/privacy">Privacy</a> ·
    <a href="/terms">Terms</a>
  </footer>
</body>
</html>
```

## `src/views/marketing/home.ejs`

```ejs
<%- include("../partials/header") %>

<section class="hero">
  <p class="eyebrow">
    FOR TEAMS THAT NEED SIGNAL, NOT MORE TABS
  </p>

  <h1>Your industry.<br>One useful daily briefing.</h1>

  <p class="lead">
    Turn the topics your company follows into a shared news feed,
    a website embed, and a daily email for your team.
  </p>

  <p class="price">$25<span>/month</span></p>

  <p>
    One company. Up to 10 confirmed recipients.
    Cancel future renewals online.
  </p>

  <form id="login-form" class="signup">
    <label for="email">Work email</label>
    <input
      id="email"
      name="email"
      type="email"
      autocomplete="email"
      placeholder="you@company.com"
      required
    >
    <button>Create my company feed →</button>
  </form>

  <p class="small">
    Sign in by email. Preview before checkout.
    No card needed to sign in.
  </p>

  <p id="message" role="status"></p>
</section>

<section class="grid">
  <article class="card">
    <h2>Choose your focus</h2>
    <p>
      Follow your industry, competitors, technologies,
      or specific keywords.
    </p>
  </article>

  <article class="card">
    <h2>Share one source</h2>
    <p>
      Give your team a consistent place to scan relevant
      headlines and source links.
    </p>
  </article>

  <article class="card">
    <h2>Publish without rebuilding</h2>
    <p>
      Use the branded RSS feed, iframe embed,
      or copyable digest on your existing site.
    </p>
  </article>
</section>

<section class="card">
  <p class="eyebrow">WHAT YOUR TEAM GETS</p>
  <h2>A briefing that fits into the workday.</h2>

  <ul>
    <li>Industry and keyword filtering</li>
    <li>Short AI-assisted summaries with source attribution</li>
    <li>Daily emails for up to 10 opted-in recipients</li>
    <li>A branded feed and embeddable news widget</li>
    <li>Rnews1-hosted stories linking back to your company</li>
  </ul>

  <p class="small">
    Summaries are based on available source material and may contain errors.
    Original reporting remains with the linked publishers.
  </p>
</section>

<section class="grid">
  <article class="card">
    <h2>Is this another newsletter?</h2>
    <p>
      You choose the topics. Your company gets a reusable feed,
      not just an email subscription.
    </p>
  </article>

  <article class="card">
    <h2>What happens after signup?</h2>
    <p>
      Confirm your email, enter your company domain,
      choose your topics, preview the feed, then activate
      your $25/month subscription.
    </p>
  </article>

  <article class="card">
    <h2>Need a custom deployment?</h2>
    <p>
      Enterprise engagements start at $10,000, subject to scope:
      dedicated hosting, custom domains, unbranded embeds,
      and advanced exclusions.
    </p>

    <a href="mailto:<%= supportEmail %>">
      Discuss enterprise →
    </a>
  </article>
</section>

<script src="/app.js" defer></script>

<%- include("../partials/footer") %>
```

## `src/views/company/dashboard.ejs`

The IDs are unchanged, so the existing `public/app.js` continues to work.

```ejs
<%- include("../partials/header") %>

<h1>Your company briefing</h1>
<p id="message" role="status"></p>

<section class="card">
  <h2>1. Choose your focus</h2>

  <form id="company-form">
    <label>
      Company name
      <input name="name" required maxlength="100">
    </label>

    <label>
      Company domain
      <input name="domain" required placeholder="example.com">
    </label>

    <label>
      Industry
      <input name="industry" required maxlength="100">
    </label>

    <label>
      Keywords, separated by commas
      <input name="keywords" maxlength="600">
    </label>

    <label>
      Briefing language
      <select name="language">
        <option value="en">English</option>
        <option value="es">Spanish</option>
        <option value="fr">French</option>
        <option value="de">German</option>
      </select>
    </label>

    <button type="button" id="suggest">Suggest topics</button>
    <button>Save and prepare preview</button>
  </form>
</section>

<section class="card">
  <h2>2. Preview and activate</h2>

  <div id="preview">Save your topics to prepare a preview.</div>

  <button id="refresh-preview">Refresh preview</button>

  <p id="billing-status"></p>

  <button id="checkout">Activate for $25/month →</button>
  <button id="portal">Manage billing / cancel renewal</button>
</section>

<section class="card">
  <h2>3. Invite your team</h2>

  <p>
    Up to 10 recipients. Each person must confirm before receiving digests.
  </p>

  <form id="invite-form">
    <label>
      Recipient email
      <input name="email" type="email" required>
    </label>

    <label class="check">
      <input name="permission" type="checkbox" required>
      This person has asked to receive this invitation.
    </label>

    <button>Send confirmation invitation</button>
  </form>

  <ul id="subscribers"></ul>
</section>

<section class="card">
  <h2>Publish your feed</h2>

  <p id="feed-links"></p>

  <label>
    Iframe embed
    <textarea id="embed-code" readonly></textarea>
  </label>

  <button id="copy-digest">Copy branded digest</button>
</section>

<button id="logout">Sign out</button>

<script src="/app.js" defer></script>

<%- include("../partials/footer") %>
```

## `src/views/auth/login.ejs`

```ejs
<%- include("../partials/header") %>

<section class="card">
  <h1>Sign in to Rnews1</h1>

  <form method="post" action="/login/<%= loginToken %>">
    <button>Continue securely →</button>
  </form>
</section>

<%- include("../partials/footer") %>
```

## `src/views/subscribers/confirm.ejs`

```ejs
<%- include("../partials/header") %>

<section class="card">
  <h1>Receive your company briefing?</h1>

  <p>
    Confirm to receive a daily Rnews1 digest.
    You can unsubscribe at any time.
  </p>

  <form method="post" action="/confirm/<%= confirmationToken %>">
    <button>Confirm my subscription</button>
  </form>
</section>

<%- include("../partials/footer") %>
```

## `src/views/subscribers/unsubscribe.ejs`

```ejs
<%- include("../partials/header") %>

<h1>Unsubscribe</h1>

<p>Stop Rnews1 marketing and digest emails to this address.</p>

<form method="post" action="/u/<%= unsubscribeToken %>">
  <button>Unsubscribe</button>
</form>

<%- include("../partials/footer") %>
```

## `src/views/message.ejs`

```ejs
<%- include("partials/header") %>

<section class="card">
  <h1><%= heading %></h1>
  <p><%= message %></p>
  <a href="/">Return to Rnews1</a>
</section>

<%- include("partials/footer") %>
```

## `src/views/partials/news-item.ejs`

```ejs
<article class="card">
  <h2>
    <a href="<%= item.hostedUrl %>"><%= item.title %></a>
  </h2>

  <p><%= item.summary %></p>

  <p class="small">
    Source: <%= item.source %> ·
    <a href="<%= item.sourceUrl %>" rel="noopener noreferrer">
      Original coverage
    </a>
  </p>
</article>
```

## `src/views/feeds/embed.ejs`

```ejs
<%- include("../partials/header") %>

<h1><%= tenant.name %> briefing</h1>

<% for (const item of items) { %>
  <%- include("../partials/news-item", { item }) %>
<% } %>

<p>
  <a
    href="https://<%= tenant.domain %>"
    target="_blank"
    rel="noopener noreferrer"
  >
    Visit <%= tenant.name %>
  </a>
</p>

<%- include("../partials/footer") %>
```

## `src/views/feeds/article.ejs`

```ejs
<%- include("../partials/header") %>

<%- include("../partials/news-item", { item }) %>

<p>
  Selected for
  <a href="https://<%= tenant.domain %>"><%= tenant.name %></a>.
</p>

<p class="small">
  AI-assisted summary, not original reporting.
  Consult the linked publisher for the full story.
</p>

<%- include("../partials/footer") %>
```

## `src/views/feeds/rss.ejs`

Start the file directly with the XML declaration—no preceding blank line.

```ejs
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title><%= tenant.name %> news — Rnews1</title>
    <link><%= appOrigin %>/embed/<%= tenant.public_token %></link>
    <description>Company news briefing powered by Rnews1</description>
    <language><%= tenant.language %></language>

    <% for (const item of items) { %>
      <item>
        <title><%= item.title %></title>
        <link><%= item.hostedUrl %></link>
        <guid isPermaLink="true"><%= item.hostedUrl %></guid>
        <description><%= item.summary %> Source: <%= item.source %>. Powered by Rnews1.</description>
        <pubDate><%= item.pubDate %></pubDate>
      </item>
    <% } %>
  </channel>
</rss>
```

## `src/views/legal/privacy.ejs`

```ejs
<%- include("../partials/header") %>

<h1>Privacy</h1>

<p>
  Rnews1 processes account details, billing identifiers, feed preferences,
  recipient subscription records, and professional contact information used
  for permitted business outreach.
</p>

<p>
  OpenAI processes the professional fields needed to produce summaries
  and personalized copy. Mailgun processes email delivery.
  Stripe processes payments.
</p>

<p>
  We retain subscription and billing records as needed to operate the
  service and meet legal obligations. We retain minimal suppression records
  to avoid contacting people who opt out. Sales briefing links expire
  after 30 days.
</p>

<p>
  For access, correction, deletion, sourcing questions, or other privacy
  requests, contact <%= supportEmail %>.
</p>

<%- include("../partials/footer") %>
```

## `src/views/legal/terms.ejs`

```ejs
<%- include("../partials/header") %>

<h1>Service terms</h1>

<p>
  The self-service plan is USD $25 per month with recurring billing,
  one company feed, and up to 10 confirmed digest recipients.
  Applicable taxes, if any, are shown at checkout.
</p>

<p>
  You may cancel future renewals through the billing portal.
  Access continues according to your subscription's paid period.
</p>

<p>
  You must have permission to invite recipients.
  Do not use the service for unlawful outreach or to infringe publisher rights.
</p>

<p>
  Summaries are AI-assisted, may be incomplete or inaccurate,
  and are not professional advice.
  Original content belongs to its respective owners.
</p>

<p>
  Contact <%= supportEmail %> for support and billing questions.
</p>

<%- include("../partials/footer") %>
```

These legal templates still need review and customization for your actual business.

---

# 10. Express initialization

## `src/app.mjs`

```javascript
import express from "express";
import helmet from "helmet";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { APP } from "./services/platform.service.mjs";

import { apiRoutes } from "./routes/api.routes.mjs";
import { siteRoutes } from "./routes/site.routes.mjs";

import {
  stripeWebhookRoutes,
  mailgunWebhookRoutes
} from "./routes/webhook.routes.mjs";

import {
  notFound,
  errorHandler
} from "./middleware/error.middleware.mjs";

const directory = path.dirname(fileURLToPath(import.meta.url));

export function createApp() {
  const app = express();

  if (process.env.TRUST_PROXY === "1") {
    app.set("trust proxy", 1);
  }

  app.disable("x-powered-by");

  app.set("view engine", "ejs");
  app.set("views", path.join(directory, "views"));

  app.locals.appOrigin = APP;
  app.locals.supportEmail = process.env.SUPPORT_EMAIL;
  app.locals.title = "Rnews1";
  app.locals.indexable = false;

  app.use(helmet({
    contentSecurityPolicy: {
      directives: {
        "script-src": ["'self'"],
        "style-src": ["'self'", "'unsafe-inline'"],
        "img-src": ["'self'", "data:"],
        "frame-ancestors": ["'self'"]
      }
    }
  }));

  /*
   * Stripe requires the original raw request body.
   * Mount its router BEFORE JSON and form parsing.
   */
  app.use("/webhooks/stripe", stripeWebhookRoutes);

  app.use(express.json({ limit: "64kb" }));
  app.use(express.urlencoded({
    extended: false,
    limit: "16kb"
  }));

  app.use("/webhooks/mailgun", mailgunWebhookRoutes);

  app.use(express.static(
    path.resolve(directory, "../public")
  ));

  app.use("/api", apiRoutes);
  app.use("/", siteRoutes);

  app.use(notFound);
  app.use(errorHandler);

  return app;
}
```

## `src/server.mjs`

```javascript
import { createApp } from "./app.mjs";
import { pool } from "./config/database.mjs";
import { validateStripePrice } from "./config/stripe.mjs";
import { APP } from "./services/platform.service.mjs";

await pool.query("SELECT 1");
await validateStripePrice();

const app = createApp();
const port = Number(process.env.PORT || 3000);

const server = app.listen(port, () => {
  console.log(`Rnews1 listening at ${APP}`);
});

let stopping = false;

async function shutdown(signal) {
  if (stopping) return;
  stopping = true;

  console.log(`Received ${signal}; shutting down.`);

  const timer = setTimeout(() => {
    process.exit(1);
  }, 10000);

  timer.unref();

  server.close(async () => {
    try {
      await pool.end();
      process.exit(0);
    } catch (error) {
      console.error(error);
      process.exit(1);
    }
  });
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
```

---

# 11. Update the worker and importer imports

## `src/workers/main.mjs`

In the moved worker, replace:

```javascript
from "./core.mjs";
```

with:

```javascript
from "../services/platform.service.mjs";
```

Keep the worker’s existing background functions:

```text
refreshOneTopic()
scheduleDigests()
planCampaign()
buildMessage()
claimJob()
deliverOne()
maintenance()
deliveryLoop()
contentLoop()
schedulerLoop()
```

They are not HTTP controllers, so they should not be imported by Express routes.

Also apply the two corrections described in the previous answer if you have not already:

1. Remove the redundant `accepted` query in `planCampaign`.
2. Retain historical topic items so recently sent article links do not immediately disappear.

Since retained topics can contain hundreds of items, change the digest payload to:

```javascript
payload: {
  company: row.name,
  publicToken: row.public_token,
  items: row.items.slice(0, 8),
  date
}
```

The refactored web controllers already limit feed and preview output to eight items.

## `scripts/import-contacts.mjs`

Replace:

```javascript
from "./core.mjs";
```

with:

```javascript
from "../src/services/platform.service.mjs";
```

The authorized CSuiteFinder export workflow and suppression protections remain unchanged.

---

# 12. Run

The database schema is unchanged:

```bash
psql "$DATABASE_URL" -f migrations/001_initial.sql
```

Start the MVC web application:

```bash
npm start
```

Start background processing separately:

```bash
npm run worker
```

Import authorized contacts:

```bash
npm run import -- ./contacts.json
```

Plan a future campaign date:

```bash
npm run plan -- 2026-08-01
```

## Result

Your web application now has clear boundaries:

| Concern | Location |
|---|---|
| Postgres persistence | `src/models/` |
| HTTP handlers | `src/controllers/` |
| HTML templates | `src/views/` |
| Route registration | `src/routes/` |
| Authentication, CSRF/origin checks, limits | `src/middleware/` |
| Stripe, Mailgun, OpenAI, PDF integrations | `src/services/` |
| Crawling, scheduling, email delivery | `src/workers/` |
| Browser behavior and styling | `public/` |

The URLs and browser API contract remain the same, so the existing frontend JavaScript, Stripe configuration, Mailgun webhooks, and mailing links continue to use the same endpoints.