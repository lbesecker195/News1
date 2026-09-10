/*
 * Exercises the real SQL against a real Postgres. Skipped unless
 * TEST_DATABASE_URL points at a scratch database that this file may wipe:
 *
 *   createdb rnews1_test
 *   TEST_DATABASE_URL=postgres://localhost/rnews1_test npm test
 *
 * Apply migrations to that database first (npm run migrate).
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { after, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("models against Postgres", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool } = await import("../src/config/database.mjs");
  const auth = await import("../src/models/auth.model.mjs");
  const companies = await import("../src/models/company.model.mjs");
  const subscribers = await import("../src/models/subscriber.model.mjs");
  const topics = await import("../src/models/topic.model.mjs");
  const digests = await import("../src/models/digest.model.mjs");
  const outbox = await import("../src/models/outbox.model.mjs");
  const briefs = await import("../src/models/brief.model.mjs");
  const events = await import("../src/models/mailgun-event.model.mjs");
  const { hash, token } = await import("../src/services/platform.service.mjs");

  after(() => pool.end());

  beforeEach(async () => {
    await pool.query(
      `TRUNCATE tenants, topics, contacts, subscribers, outbox, briefs,
                mailgun_events, paypal_events, paypal_plans, stories,
                newsletter_picks, advertisers, campaigns, creatives,
                ad_placements, ad_events, login_tokens, sessions
       RESTART IDENTITY CASCADE`
    );
  });

  const settings = {
    name: "Acme Robotics",
    domain: "acme.test",
    industry: "Robotics",
    keywords: ["grippers"],
    language: "en"
  };

  const topic = { key: hash("en:acme"), query: '"Robotics" OR "grippers"' };

  async function activeTenant() {
    const secret = token();

    const tenantId = await auth.createLogin({
      email: "owner@acme.test",
      tokenHash: hash(secret),
      url: "https://rnews1.test/login/x"
    });

    await companies.saveSettings(tenantId, settings, topic);

    await pool.query(
      "UPDATE tenants SET paypal_subscription_id='I-SUB1' WHERE id=$1",
      [tenantId]
    );

    await companies.syncSubscription({
      subscriptionId: "I-SUB1",
      status: "active"
    });

    return tenantId;
  }

  describe("authentication", () => {
    it("creates a tenant, a token and a queued email in one transaction", async () => {
      const secret = token();

      const tenantId = await auth.createLogin({
        email: "owner@acme.test",
        tokenHash: hash(secret),
        url: "https://rnews1.test/login/x"
      });

      const { rows } = await pool.query(
        "SELECT kind, to_email, status FROM outbox WHERE tenant_id=$1",
        [tenantId]
      );

      assert.deepEqual(rows, [
        { kind: "login", to_email: "owner@acme.test", status: "pending" }
      ]);
    });

    it("treats a repeat sign-in as the same tenant", async () => {
      const first = await auth.createLogin({
        email: "Owner@Acme.test",
        tokenHash: hash(token()),
        url: "u"
      });

      const second = await auth.createLogin({
        email: "owner@acme.test",
        tokenHash: hash(token()),
        url: "u"
      });

      assert.equal(first, second, "citext owner_email matched case-insensitively");
    });

    it("burns the login token so a link cannot be replayed", async () => {
      const secret = token();

      await auth.createLogin({
        email: "owner@acme.test",
        tokenHash: hash(secret),
        url: "u"
      });

      const sessionSecret = token();

      const tenantId = await auth.consumeLoginAndCreateSession({
        loginHash: hash(secret),
        sessionHash: hash(sessionSecret)
      });

      assert.ok(tenantId);

      assert.equal(
        await auth.consumeLoginAndCreateSession({
          loginHash: hash(secret),
          sessionHash: hash(token())
        }),
        null,
        "second use of the same link"
      );

      const tenant = await auth.findTenantBySession(hash(sessionSecret));
      assert.equal(tenant.owner_email, "owner@acme.test");

      await auth.deleteSession(hash(sessionSecret));
      assert.equal(await auth.findTenantBySession(hash(sessionSecret)), null);
    });

    it("ignores an expired session", async () => {
      const tenantId = await activeTenant();

      await pool.query(
        `INSERT INTO sessions(hash,tenant_id,expires_at)
         VALUES($1,$2,now()-interval '1 second')`,
        [hash("stale"), tenantId]
      );

      assert.equal(await auth.findTenantBySession(hash("stale")), null);
    });
  });

  describe("company settings and the public feed", () => {
    it("shares one topic row between tenants with the same query", async () => {
      const first = await activeTenant();

      const second = await auth.createLogin({
        email: "other@beta.test",
        tokenHash: hash(token()),
        url: "u"
      });

      await companies.saveSettings(second, settings, topic);

      const { rows } = await pool.query("SELECT count(*)::int AS n FROM topics");
      assert.equal(rows[0].n, 1);

      const preview = await companies.findPreview(topic.key);
      assert.deepEqual(preview.items, []);
      assert.equal(preview.refreshed_at, null);
      assert.ok(first);
    });

    it("returns an empty preview rather than throwing on a tenant with no topic", async () => {
      assert.deepEqual(
        await companies.findPreview(null),
        { items: [], refreshed_at: null }
      );
    });

    it("publishes the feed only while billing is live", async () => {
      const tenantId = await activeTenant();

      const { rows } = await pool.query(
        "SELECT public_token FROM tenants WHERE id=$1",
        [tenantId]
      );

      const publicToken = rows[0].public_token;

      assert.ok(await companies.findPublicTenant(publicToken));

      for (const status of ["cancelled", "past_due", "suspended", "expired",
        "approval_pending", "inactive"]) {
        await pool.query("UPDATE tenants SET billing_status=$2 WHERE id=$1",
          [tenantId, status]);

        assert.equal(
          await companies.findPublicTenant(publicToken),
          null,
          `feed must be down while ${status}`
        );
      }

      await pool.query("UPDATE tenants SET billing_status='active' WHERE id=$1",
        [tenantId]);

      assert.ok(await companies.findPublicTenant(publicToken), "active is live");
    });

    it("reports the stakeholder count the publish gate reads", async () => {
      const tenantId = await activeTenant();

      const { rows } = await pool.query(
        "SELECT public_token FROM tenants WHERE id=$1",
        [tenantId]
      );

      const publicToken = rows[0].public_token;

      /* Paying, but nobody on the roster yet: the row resolves, unpublished. */
      let tenant = await companies.findPublicTenant(publicToken);

      assert.equal(tenant.stakeholder_count, 0);

      for (let n = 0; n < 10; n++) {
        await subscribers.addRecipient({
          tenantId,
          email: `stakeholder${n}@acme.test`,
          authorisedBy: "owner@acme.test"
        });
      }

      tenant = await companies.findPublicTenant(publicToken);

      assert.equal(tenant.stakeholder_count, 10);

      /*
       * Pending invitations still count. Whether an invitee clicks the link is
       * not something the paying customer controls.
       */
      const states = await pool.query(
        "SELECT DISTINCT state FROM subscribers WHERE tenant_id=$1",
        [tenantId]
      );

      assert.deepEqual(states.rows, [{ state: "active" }]);
    });

    it("ignores a webhook for a subscription no tenant owns", async () => {
      const tenantId = await activeTenant();

      assert.equal(
        await companies.syncSubscription({
          subscriptionId: "I-NOBODY",
          status: "cancelled"
        }),
        false,
        "nothing was updated"
      );

      const { rows } = await pool.query(
        "SELECT billing_status FROM tenants WHERE id=$1",
        [tenantId]
      );

      assert.equal(rows[0].billing_status, "active", "untouched");
    });

    it("will not let two tenants claim one PayPal subscription", async () => {
      await activeTenant();

      const other = await auth.createLogin({
        email: "other@beta.test",
        tokenHash: hash(token()),
        url: "u"
      });

      await assert.rejects(
        () => pool.query(
          "UPDATE tenants SET paypal_subscription_id='I-SUB1' WHERE id=$1",
          [other]
        ),
        /duplicate key|unique/i
      );
    });
  });

  describe("topics", () => {
    it("leases one topic at a time and stores its items", async () => {
      await activeTenant();

      const claimed = await topics.claimStaleTopic();
      assert.equal(claimed.key, topic.key);

      /* Leased: a second worker gets nothing until the lease expires. */
      assert.equal(await topics.claimStaleTopic(), null);

      await topics.saveItems(topic.key, [{ id: "a", title: "T" }]);

      const preview = await companies.findPreview(topic.key);
      assert.equal(preview.items.length, 1);
      assert.ok(preview.refreshed_at);
    });

    it("backs a failing topic off instead of spinning on it", async () => {
      await activeTenant();
      await topics.claimStaleTopic();
      await topics.recordFailure(topic.key, "Google News 429");

      const { rows } = await pool.query(
        "SELECT last_error, refresh_after > now() AS deferred FROM topics"
      );

      assert.equal(rows[0].last_error, "Google News 429");
      assert.equal(rows[0].deferred, true);
    });
  });

  describe("subscribers", () => {
    it("requires an active subscription", async () => {
      const secret = token();

      const tenantId = await auth.createLogin({
        email: "owner@acme.test",
        tokenHash: hash(secret),
        url: "u"
      });

      await assert.rejects(
        () => subscribers.addRecipient({
          tenantId,
          email: "reader@acme.test",
          authorisedBy: "owner@acme.test"
        }),
        /Activate your subscription/
      );
    });

    it("adds a recipient active, on the attestation, with no invitation", async () => {
      const tenantId = await activeTenant();

      await subscribers.addRecipient({
        tenantId,
        email: "reader@acme.test",
        authorisedBy: "owner@acme.test"
      });

      /* Active immediately: there is no confirmation step to wait for. */
      assert.deepEqual(
        await subscribers.listForTenant(tenantId),
        [{ email: "reader@acme.test", state: "active" }]
      );

      /* And nothing was mailed to ask permission. */
      const queued = await pool.query(
        "SELECT count(*)::int AS n FROM outbox WHERE kind='confirmation'"
      );

      assert.equal(queued.rows[0].n, 0);

      /* The attestation is recorded as the evidence it is. */
      const row = await pool.query(
        `SELECT authorised_by, authorised_at IS NOT NULL AS stamped
         FROM subscribers`
      );

      assert.deepEqual(row.rows[0], {
        authorised_by: "owner@acme.test",
        stamped: true
      });

      await assert.rejects(
        () => subscribers.addRecipient({
          tenantId,
          email: "reader@acme.test",
          authorisedBy: "owner@acme.test"
        }),
        /already on your list/
      );
    });

    it("accepts more recipients than the stakeholder requirement", async () => {
      const tenantId = await activeTenant();

      /* The ten is a floor for publishing, never a ceiling on sending. */
      for (let n = 0; n < 14; n++) {
        await subscribers.addRecipient({
          tenantId,
          email: `reader${n}@acme.test`,
          authorisedBy: "owner@acme.test"
        });
      }

      assert.equal(await subscribers.countForTenant(tenantId), 14);
    });

    it("counts the roster without anyone who has unsubscribed", async () => {
      const tenantId = await activeTenant();

      await subscribers.addRecipient({
        tenantId,
        email: "reader@acme.test",
        authorisedBy: "owner@acme.test"
      });

      assert.equal(await subscribers.countForTenant(tenantId), 1);

      await pool.query("UPDATE subscribers SET state='unsubscribed'");

      assert.equal(await subscribers.countForTenant(tenantId), 0);
    });

    it("enrols the owner as the first stakeholder, once", async () => {
      const tenantId = await activeTenant();

      const enrol = () => pool.query("BEGIN")
        .then(() => subscribers.enrolOwner(pool, tenantId, "owner@acme.test"))
        .finally(() => pool.query("COMMIT"));

      assert.equal(await enrol(), true);
      assert.equal(await enrol(), false, "idempotent across renewals");

      assert.deepEqual(
        await subscribers.listForTenant(tenantId),
        [{ email: "owner@acme.test", state: "active" }]
      );
    });

    it("refuses a suppressed address whatever the customer attests", async () => {
      const tenantId = await activeTenant();

      await pool.query(
        "INSERT INTO contacts(email, opted_out_at) VALUES($1, now())",
        ["gone@acme.test"]
      );

      /*
       * The attestation does not outrank a suppression. Someone who opted out
       * stays off the list no matter who claims the right to mail them.
       */
      await assert.rejects(
        () => subscribers.addRecipient({
          tenantId,
          email: "gone@acme.test",
          authorisedBy: "owner@acme.test"
        }),
        /suppressed/
      );

      assert.deepEqual(await subscribers.listForTenant(tenantId), []);
    });

    it("re-adds someone who previously unsubscribed from this tenant", async () => {
      const tenantId = await activeTenant();

      await subscribers.addRecipient({
        tenantId,
        email: "reader@acme.test",
        authorisedBy: "owner@acme.test"
      });

      await pool.query("UPDATE subscribers SET state='unsubscribed'");

      await subscribers.addRecipient({
        tenantId,
        email: "reader@acme.test",
        authorisedBy: "owner@acme.test"
      });

      assert.deepEqual(
        await subscribers.listForTenant(tenantId),
        [{ email: "reader@acme.test", state: "active" }]
      );
    });

    it("an opt-out suppresses queued mail but never a sign-in link", async () => {
      const tenantId = await activeTenant();

      await subscribers.addRecipient({
        tenantId,
        email: "reader@acme.test",
        authorisedBy: "owner@acme.test"
      });

      const { rows } = await pool.query(
        "SELECT unsub_token, id FROM contacts WHERE email='reader@acme.test'"
      );

      await pool.query(
        `INSERT INTO outbox(contact_id,to_email,kind,payload)
         VALUES($1,'reader@acme.test','login','{}')`,
        [rows[0].id]
      );

      assert.equal(await subscribers.unsubscribe(rows[0].unsub_token), true);

      const after = await pool.query(
        "SELECT kind, status FROM outbox ORDER BY kind"
      );

      /* The sign-in links survive: they are transactional, not marketing. */
      assert.deepEqual(after.rows, [
        { kind: "login", status: "pending" },
        { kind: "login", status: "pending" }
      ]);

      assert.deepEqual(
        await subscribers.listForTenant(tenantId),
        [{ email: "reader@acme.test", state: "unsubscribed" }]
      );

      assert.equal(await subscribers.unsubscribe(rows[0].unsub_token), true);
      assert.equal(await subscribers.unsubscribe(
        "550e8400-e29b-41d4-a716-446655440000"
      ), false);
    });
  });

  describe("digest scheduling", () => {
    async function readyTenant() {
      const tenantId = await activeTenant();

      await topics.claimStaleTopic();
      await topics.saveItems(topic.key, [
        { id: "a", title: "One", summary: "s", source: "src", url: "https://x/1" }
      ]);

      await subscribers.addRecipient({
        tenantId,
        email: "reader@acme.test",
        authorisedBy: "owner@acme.test"
      });

      const { rows } = await pool.query("SELECT confirm_token FROM subscribers");
      await subscribers.confirm(rows[0].confirm_token);

      return tenantId;
    }

    it("queues one digest per confirmed recipient, once a day", async () => {
      await readyTenant();

      const run = () => digests.withTenantDueForDigest("2026-09-09", async (tenant, db) => {
        const briefId = await briefs.create(db, {
          tenantId: tenant.id,
          html: "<p>brief</p>"
        });

        for (const recipient of tenant.recipients) {
          await db.query(
            `INSERT INTO outbox(tenant_id,contact_id,to_email,kind,payload,dedupe_key)
             VALUES($1,$2,$3,'digest','{}',$4)
             ON CONFLICT (dedupe_key) DO NOTHING`,
            [
              tenant.id,
              recipient.contact_id,
              recipient.email,
              `digest:${tenant.id}:${recipient.contact_id}:2026-09-09`
            ]
          );
        }

        return { briefId, recipients: tenant.recipients.length };
      });

      const first = await run();

      assert.equal(first.recipients, 1);
      assert.ok(first.briefId);

      /* digest_sent_on now guards the day. */
      assert.equal(await run(), null);

      const { rows } = await pool.query(
        "SELECT count(*)::int AS n FROM outbox WHERE kind='digest'"
      );

      assert.equal(rows[0].n, 1);
    });

    it("skips a tenant with no recipients", async () => {
      await activeTenant();

      await topics.claimStaleTopic();
      await topics.saveItems(topic.key, []);

      assert.equal(
        await digests.withTenantDueForDigest("2026-09-09", async () => "ran"),
        null
      );
    });

    it("excludes a recipient suppressed after confirming", async () => {
      await readyTenant();

      await pool.query("UPDATE contacts SET bounced_at=now()");

      const recipients = await digests.withTenantDueForDigest(
        "2026-09-09",
        async tenant => tenant.recipients
      );

      assert.deepEqual(recipients, []);
    });
  });

  describe("the outbox queue", () => {
    async function queued(overrides = "") {
      const tenantId = await activeTenant();

      /* activeTenant() queues a sign-in email of its own; start from empty. */
      await pool.query("DELETE FROM outbox");

      const { rows } = await pool.query(
        `INSERT INTO outbox(tenant_id,to_email,kind,payload${overrides ? "," + overrides.split("=")[0] : ""})
         VALUES($1,'owner@acme.test','login','{}'${overrides ? "," + overrides.split("=")[1] : ""})
         RETURNING id`,
        [tenantId]
      );

      return rows[0].id;
    }

    it("claims a job exactly once", async () => {
      await queued();

      const job = await outbox.claimJob();

      assert.equal(job.status, "processing");
      assert.equal(job.attempts, 1);
      assert.equal(await outbox.claimJob(), null, "already claimed");
    });

    it("does not claim a job whose run_after is in the future", async () => {
      await queued("run_after=now() + interval '1 hour'");

      assert.equal(await outbox.claimJob(), null);
    });

    it("does not claim a job that has already expired", async () => {
      await queued("expires_at=now() - interval '1 second'");

      assert.equal(await outbox.claimJob(), null);
      assert.equal(await outbox.expireStale(), 1);
    });

    it("backs off a retry and recovers a job whose worker died", async () => {
      const id = await queued();
      const job = await outbox.claimJob();

      await outbox.retryLater(id, job.attempts, "Mailgun 503");

      const backedOff = await pool.query(
        "SELECT status, run_after > now() AS later FROM outbox WHERE id=$1",
        [id]
      );

      assert.deepEqual(backedOff.rows[0], { status: "pending", later: true });

      await pool.query("UPDATE outbox SET run_after=now() WHERE id=$1", [id]);
      await outbox.claimJob();
      await pool.query(
        "UPDATE outbox SET locked_at=now() - interval '1 hour' WHERE id=$1",
        [id]
      );

      assert.equal(await outbox.requeueStuck(), 1);
    });

    it("fails a job that has used up its attempts", async () => {
      const id = await queued();

      await pool.query(
        `UPDATE outbox SET attempts=$2, status='processing',
                           locked_at=now() - interval '1 hour'
         WHERE id=$1`,
        [id, outbox.MAX_ATTEMPTS]
      );

      assert.equal(await outbox.requeueStuck(), 0, "not retried forever");
      assert.equal(await outbox.failExhausted(), 1);
    });

    it("refuses to queue the same dedupe key twice", async () => {
      const tenantId = await activeTenant();
      const { enqueue } = await import("../src/services/platform.service.mjs");

      const first = await enqueue(pool, {
        tenantId,
        toEmail: "owner@acme.test",
        kind: "digest",
        dedupeKey: "digest:x:2026-09-09"
      });

      const second = await enqueue(pool, {
        tenantId,
        toEmail: "owner@acme.test",
        kind: "digest",
        dedupeKey: "digest:x:2026-09-09"
      });

      assert.ok(first);
      assert.equal(second, null, "second insert was a no-op");
    });
  });

  describe("mailgun events", () => {
    it("applies an event once, however many times it is delivered", async () => {
      const tenantId = await activeTenant();

      const { rows } = await pool.query(
        `INSERT INTO outbox(tenant_id,to_email,kind,payload,status)
         VALUES($1,'owner@acme.test','login','{}','processing')
         RETURNING id`,
        [tenantId]
      );

      const event = {
        id: "evt-1",
        kind: "delivered",
        jobId: rows[0].id,
        email: "owner@acme.test"
      };

      assert.equal(await events.recordAndApply(event), true);
      assert.equal(await events.recordAndApply(event), false, "redelivery");

      const job = await pool.query("SELECT status FROM outbox WHERE id=$1",
        [rows[0].id]);

      assert.equal(job.rows[0].status, "accepted");
    });

    it("suppresses the contact everywhere on a complaint", async () => {
      const tenantId = await activeTenant();

      await subscribers.addRecipient({
        tenantId,
        email: "reader@acme.test",
        authorisedBy: "owner@acme.test"
      });

      await events.recordAndApply({
        id: "evt-2",
        kind: "complained",
        jobId: null,
        email: "reader@acme.test"
      });

      const contact = await pool.query(
        "SELECT opted_out_at IS NOT NULL AS out FROM contacts WHERE email=$1",
        ["reader@acme.test"]
      );

      assert.equal(contact.rows[0].out, true);
      assert.deepEqual(
        await subscribers.listForTenant(tenantId),
        [{ email: "reader@acme.test", state: "unsubscribed" }]
      );

      /*
       * Nothing is queued for this contact at this point — the suppression
       * that matters is on the contact itself, which stops every future send.
       */
      const contactRow = await pool.query(
        "SELECT opted_out_at IS NOT NULL AS out FROM contacts WHERE email=$1",
        ["reader@acme.test"]
      );

      assert.equal(contactRow.rows[0].out, true);
    });

    it("records a hard bounce against contact and job", async () => {
      const tenantId = await activeTenant();

      const { rows } = await pool.query(
        `INSERT INTO outbox(tenant_id,to_email,kind,payload,status)
         VALUES($1,'reader@acme.test','digest','{}','unknown')
         RETURNING id`,
        [tenantId]
      );

      await pool.query("INSERT INTO contacts(email) VALUES('reader@acme.test')");

      await events.recordAndApply({
        id: "evt-3",
        kind: "hard_bounce",
        jobId: rows[0].id,
        email: "reader@acme.test"
      });

      const job = await pool.query("SELECT status FROM outbox WHERE id=$1",
        [rows[0].id]);
      const contact = await pool.query(
        "SELECT bounced_at IS NOT NULL AS bounced FROM contacts"
      );

      assert.equal(job.rows[0].status, "failed");
      assert.equal(contact.rows[0].bounced, true);
    });

    it("keeps an event whose outbox row has already been pruned", async () => {
      await assert.doesNotReject(() => events.recordAndApply({
        id: "evt-4",
        kind: "delivered",
        jobId: "550e8400-e29b-41d4-a716-446655440000",
        email: "nobody@acme.test"
      }));
    });
  });

  describe("maintenance", () => {
    it("clears expired auth rows and old events", async () => {
      const tenantId = await activeTenant();

      /* Drop the live token createLogin issued, so only expired rows remain. */
      await pool.query("DELETE FROM login_tokens");

      await pool.query(
        `INSERT INTO login_tokens(hash,tenant_id,expires_at)
         VALUES('h',$1,now()-interval '1 hour')`,
        [tenantId]
      );

      await pool.query(
        `INSERT INTO sessions(hash,tenant_id,expires_at)
         VALUES('h',$1,now()-interval '1 hour')`,
        [tenantId]
      );

      await pool.query(
        `INSERT INTO mailgun_events(id,kind,received_at)
         VALUES('old','delivered',now()-interval '90 days')`
      );

      await outbox.pruneAuth();

      assert.equal(await outbox.pruneEvents(), 1);

      const remaining = await pool.query(
        `SELECT (SELECT count(*) FROM login_tokens)
              + (SELECT count(*) FROM sessions) AS n`
      );

      assert.equal(Number(remaining.rows[0].n), 0);
    });

    it("removes expired briefs and reports which had a PDF", async () => {
      const tenantId = await activeTenant();

      await pool.query(
        `INSERT INTO briefs(tenant_id,html,has_pdf,expires_at)
         VALUES($1,'<p>x</p>',true,now()-interval '1 day')`,
        [tenantId]
      );

      const removed = await briefs.deleteExpired();

      assert.equal(removed.length, 1);
      assert.equal(removed[0].has_pdf, true);
    });

    it("parks a topic no tenant watches any more", async () => {
      await pool.query(
        "INSERT INTO topics(key,query,language) VALUES('orphan','q','en')"
      );

      assert.equal(await topics.parkUnused(), 1);
      assert.equal(await topics.claimStaleTopic(), null);
    });
  });
});
