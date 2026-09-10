import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  companyDomain,
  escapeHtml,
  hash,
  safeURL,
  token
} from "../src/services/platform.service.mjs";

describe("companyDomain", () => {
  it("normalises what people actually type", () => {
    for (const [input, expected] of [
      ["example.com", "example.com"],
      ["  Example.COM  ", "example.com"],
      ["https://www.example.com/about?x=1", "example.com"],
      ["http://example.com:8080", "example.com"],
      ["news.example.co.uk", "news.example.co.uk"],
      ["someone@example.com", "example.com"],
      ["example.com.", "example.com"]
    ]) {
      assert.equal(companyDomain(input), expected, input);
    }
  });

  it("rejects anything that is not a hostname", () => {
    for (const input of ["", "   ", "localhost", "not a domain", "..", "-x.com",
      "javascript:alert(1)", "example", "example.c"]) {
      assert.throws(() => companyDomain(input), /domain/i, input);
    }
  });
});

describe("safeURL", () => {
  it("passes through http and https", () => {
    assert.equal(safeURL("https://news.example.com/a"), "https://news.example.com/a");
    assert.equal(safeURL("http://x.test/"), "http://x.test/");
  });

  it("neutralises every other scheme", () => {
    for (const input of [
      "javascript:alert(1)",
      "data:text/html,<script>x</script>",
      "file:///etc/passwd",
      "not a url",
      "",
      null,
      undefined
    ]) {
      assert.equal(safeURL(input), "#", String(input));
    }
  });
});

describe("escapeHtml", () => {
  it("escapes every character that can break out of markup", () => {
    assert.equal(
      escapeHtml(`<script>alert("x" & 'y')</script>`),
      "&lt;script&gt;alert(&quot;x&quot; &amp; &#39;y&#39;)&lt;/script&gt;"
    );
  });

  it("renders nullish values as empty", () => {
    assert.equal(escapeHtml(null), "");
    assert.equal(escapeHtml(undefined), "");
  });
});

describe("token and hash", () => {
  it("issues 43-character base64url secrets", () => {
    const secret = token();

    assert.match(secret, /^[A-Za-z0-9_-]{43}$/);
    assert.notEqual(secret, token());
  });

  it("hashes deterministically to 64 hex characters", () => {
    assert.equal(hash("a"), hash("a"));
    assert.notEqual(hash("a"), hash("b"));
    assert.match(hash("a"), /^[a-f0-9]{64}$/);
  });
});
