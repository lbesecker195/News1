import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";

import { aiJSON } from "../src/services/openai.service.mjs";

const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

const reply = value => new Response(JSON.stringify({
  choices: [{ message: { content: JSON.stringify(value) } }]
}), { status: 200 });

describe("aiJSON", () => {
  it("names JSON in the prompt, which the API requires", async () => {
    /*
     * response_format: json_object is refused with a 400 unless the word
     * "json" appears in the messages. Every prompt in this codebase shows the
     * shape it wants — {"stories":[…]} — without naming it, so the word is
     * appended centrally. Without this, every model call in the product fails.
     */
    let sent;

    globalThis.fetch = async (url, init) => {
      sent = JSON.parse(init.body);
      return reply({ ok: true });
    };

    await aiJSON("Return {\"ok\":true}.", { ping: 1 });

    const words = sent.messages.map(m => m.content).join(" ").toLowerCase();

    assert.ok(words.includes("json"), "the word 'json' reaches the API");
    assert.equal(sent.response_format.type, "json_object");
  });

  it("keeps the caller's instruction intact", async () => {
    let sent;

    globalThis.fetch = async (url, init) => {
      sent = JSON.parse(init.body);
      return reply({ ok: true });
    };

    await aiJSON("Do the specific thing I asked.", { a: 1 });

    assert.match(sent.messages[0].content, /^Do the specific thing I asked\./);
    assert.equal(sent.messages[1].content, JSON.stringify({ a: 1 }));
  });

  it("parses the model's answer", async () => {
    globalThis.fetch = async () => reply({ stories: [{ id: "a" }] });

    assert.deepEqual(await aiJSON("x", {}), { stories: [{ id: "a" }] });
  });

  it("strips a fenced code block the model wrapped it in", async () => {
    globalThis.fetch = async () => new Response(JSON.stringify({
      choices: [{ message: { content: '```json\n{"ok":true}\n```' } }]
    }), { status: 200 });

    assert.deepEqual(await aiJSON("x", {}), { ok: true });
  });

  it("does not retry a 400, which will fail identically every time", async () => {
    let calls = 0;

    globalThis.fetch = async () => {
      calls++;
      return new Response('{"error":{"message":"bad request"}}', { status: 400 });
    };

    await assert.rejects(() => aiJSON("x", {}), /OpenAI 400/);
    assert.equal(calls, 1, "a bad request is the caller's bug, not a blip");
  });

  it("retries a 429 and gives up after the limit", async () => {
    let calls = 0;

    globalThis.fetch = async () => {
      calls++;
      return new Response("{}", { status: 429 });
    };

    await assert.rejects(() => aiJSON("x", {}, { maxRetries: 2 }), /OpenAI 429/);
    assert.equal(calls, 3, "the first try plus two retries");
  });

  it("refuses an empty completion rather than returning nothing", async () => {
    globalThis.fetch = async () => new Response(JSON.stringify({
      choices: [{ message: { content: "" } }]
    }), { status: 200 });

    await assert.rejects(() => aiJSON("x", {}), /empty completion/);
  });
});
