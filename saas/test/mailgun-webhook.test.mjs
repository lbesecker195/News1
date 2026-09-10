import "./helpers/env.mjs";

import assert from "node:assert/strict";
import crypto from "node:crypto";
import { beforeEach, describe, it, mock } from "node:test";

import { processMailgunWebhook as verify } from "../src/services/mailgun-webhook.service.mjs";

const KEY = process.env.MAILGUN_WEBHOOK_SIGNING_KEY;

function signed(eventData, overrides = {}) {
  const timestamp = String(Math.floor(Date.now() / 1000));
  const token = "t".repeat(50);

  return {
    signature: {
      timestamp,
      token,
      signature: crypto.createHmac("sha256", KEY)
        .update(timestamp + token)
        .digest("hex"),
      ...overrides
    },
    "event-data": eventData
  };
}

const DELIVERED = {
  id: "evt-1",
  event: "delivered",
  recipient: "Person@Example.com",
  "user-variables": { job_id: "550e8400-e29b-41d4-a716-446655440000" }
};

/*
 * The model is the boundary: these tests are about what gets past the guard,
 * so the applier is injected and simply records what it was handed.
 */
const applied = mock.fn(async () => true);

const processMailgunWebhook = body => verify(body, applied);

beforeEach(() => applied.mock.resetCalls());

describe("processMailgunWebhook", () => {
  it("accepts a correctly signed event", async () => {
    await processMailgunWebhook(signed(DELIVERED));

    assert.equal(applied.mock.callCount(), 1);
    assert.deepEqual(applied.mock.calls[0].arguments[0], {
      id: "evt-1",
      kind: "delivered",
      jobId: "550e8400-e29b-41d4-a716-446655440000",
      email: "person@example.com"
    });
  });

  it("rejects a forged or altered signature", async () => {
    const cases = [
      ["wrong hmac", { signature: "0".repeat(64) }],
      ["truncated hmac", { signature: "abc" }],
      ["non-hex hmac", { signature: "z".repeat(64) }],
      ["missing timestamp", { timestamp: "" }],
      ["non-numeric timestamp", { timestamp: "not-a-number" }],
      ["replayed from last week", {
        timestamp: String(Math.floor(Date.now() / 1000) - 604800)
      }]
    ];

    for (const [label, overrides] of cases) {
      await assert.rejects(
        () => processMailgunWebhook(signed(DELIVERED, overrides)),
        /Invalid Mailgun signature/,
        label
      );
    }

    assert.equal(applied.mock.callCount(), 0, "nothing was applied");
  });

  it("rejects a body with no event in it", async () => {
    await assert.rejects(
      () => processMailgunWebhook(signed({ id: "x" })),
      /Invalid Mailgun event/
    );

    await assert.rejects(
      () => processMailgunWebhook({}),
      /Invalid Mailgun signature/
    );
  });

  it("maps only permanent failures to a hard bounce", async () => {
    await processMailgunWebhook(signed({
      ...DELIVERED, event: "failed", severity: "permanent"
    }));

    await processMailgunWebhook(signed({
      ...DELIVERED, event: "failed", severity: "temporary"
    }));

    assert.deepEqual(
      applied.mock.calls.map(call => call.arguments[0].kind),
      ["hard_bounce", "failed"]
    );
  });

  it("drops a job id that is not a UUID rather than passing it to SQL", async () => {
    await processMailgunWebhook(signed({
      ...DELIVERED,
      "user-variables": { job_id: "1; DROP TABLE outbox" }
    }));

    assert.equal(applied.mock.calls[0].arguments[0].jobId, null);
  });
});
