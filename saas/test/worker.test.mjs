import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { UnbuildableMessage, buildMessage } from "../src/workers/main.mjs";

/*
 * The message kinds that need no database. A personalised issue reads stories,
 * picks and ad inventory, so it is covered in newsletter.integration.test.mjs
 * against a real one.
 */
describe("buildMessage", () => {
  const jobs = [
    { kind: "login", payload: { url: "https://rnews1.test/login/x" } },
    {
      kind: "confirmation",
      payload: { company: "Acme", url: "https://rnews1.test/confirm/x" }
    },
    {
      kind: "campaign",
      payload: { name: "Dana", unsubscribeUrl: "https://rnews1.test/u/tok" }
    }
  ];

  it("builds every kind that does not need a database", async () => {
    for (const job of jobs) {
      const message = await buildMessage(job);

      assert.ok(message.subject, `${job.kind} subject`);
      assert.ok(message.text, `${job.kind} text part`);
      assert.ok(message.html.startsWith("<!doctype html>"), `${job.kind} html`);
      assert.ok(!message.html.includes("undefined"), `${job.kind} undefined`);
      assert.ok(!message.text.includes("undefined"), `${job.kind} undefined text`);
    }
  });

  it("marks an unknown kind unbuildable so it is not retried five times", async () => {
    await assert.rejects(
      () => buildMessage({ kind: "nope", payload: {} }),
      error => {
        assert.ok(error instanceof UnbuildableMessage);
        assert.match(error.message, /Unknown outbox kind/);
        return true;
      }
    );
  });

  /*
   * CAN-SPAM § 7704(a)(5)(A)(iii) requires a postal address in every
   * commercial message. Transactional relationship messages — a sign-in link,
   * a confirmation — are exempt, and putting one there would only be noise.
   */
  it("carries a postal address in commercial mail, and only there", async () => {
    const address = process.env.BUSINESS_ADDRESS;

    const campaign = await buildMessage(jobs[2]);

    assert.ok(campaign.html.includes(address), "campaign html");
    assert.ok(campaign.text.includes(address), "campaign text");

    for (const job of [jobs[0], jobs[1]]) {
      const message = await buildMessage(job);

      assert.ok(!message.html.includes(address), `${job.kind} html`);
      assert.ok(!message.text.includes(address), `${job.kind} text`);
    }
  });

  it("adds one-click unsubscribe headers to bulk mail only", async () => {
    const campaign = await buildMessage(jobs[2]);

    assert.deepEqual(campaign.headers, {
      "List-Unsubscribe": "<https://rnews1.test/u/tok>",
      "List-Unsubscribe-Post": "List-Unsubscribe=One-Click"
    });

    /* Transactional mail must not offer to unsubscribe from sign-in links. */
    const login = await buildMessage(jobs[0]);

    assert.equal(login.headers, undefined);
  });

  it("escapes recipient-controlled values in the html part", async () => {
    const message = await buildMessage({
      kind: "campaign",
      payload: {
        name: '<script>alert(1)</script>',
        unsubscribeUrl: "https://rnews1.test/u/tok"
      }
    });

    assert.ok(!message.html.includes("<script>alert(1)</script>"));
    assert.ok(message.html.includes("&lt;script&gt;"));
  });
});
