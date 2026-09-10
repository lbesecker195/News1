import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  companySchema,
  emailSchema,
  recipientSchema,
  isLoginToken,
  isUUID,
  suggestionResultSchema
} from "../src/utils/validation.mjs";

import { readCookie } from "../src/utils/cookies.mjs";

describe("emailSchema", () => {
  it("trims and lowercases", () => {
    assert.equal(emailSchema.parse("  Person@Example.COM "), "person@example.com");
  });

  it("rejects what is not an address", () => {
    for (const input of ["", "person", "person@", "@example.com", "a b@c.com",
      "person@example", `${"a".repeat(250)}@example.com`]) {
      assert.throws(() => emailSchema.parse(input), JSON.stringify(input));
    }
  });
});

describe("isUUID / isLoginToken", () => {
  it("accepts the real shapes and nothing else", () => {
    assert.ok(isUUID("550e8400-e29b-41d4-a716-446655440000"));
    assert.ok(!isUUID("550e8400e29b41d4a716446655440000"));
    assert.ok(!isUUID("../../etc/passwd"));
    assert.ok(!isUUID(null));
    assert.ok(!isUUID(undefined));
    assert.ok(!isUUID(["550e8400-e29b-41d4-a716-446655440000"]));

    assert.ok(isLoginToken("a".repeat(43)));
    assert.ok(!isLoginToken("a".repeat(42)));
    assert.ok(!isLoginToken(`${"a".repeat(42)}+`));
    assert.ok(!isLoginToken(null));
  });
});

describe("companySchema", () => {
  const valid = {
    name: "Acme",
    domain: "acme.test",
    industry: "Robotics",
    keywords: ["automation", "grippers"],
    language: "en"
  };

  it("accepts a filled-in form", () => {
    assert.deepEqual(companySchema.parse(valid), valid);
  });

  it("requires exactly two keywords and a supported language", () => {
    for (const keywords of [[], ["one"], ["one", "two", "three"]]) {
      assert.throws(
        () => companySchema.parse({ ...valid, keywords }),
        `${keywords.length} keywords`
      );
    }

    assert.throws(() => companySchema.parse({ ...valid, language: "jp" }));
  });
});

describe("recipientSchema", () => {
  it("requires the authority attestation to be ticked", () => {
    /*
     * There is no confirmation email any more, so this checkbox is the only
     * record that anyone claimed the right to mail this person. An unticked or
     * absent value must never parse.
     */
    assert.throws(() => recipientSchema.parse({ email: "a@b.com" }));
    assert.throws(() => recipientSchema.parse({ email: "a@b.com", authorised: false }));
    assert.throws(() => recipientSchema.parse({ email: "a@b.com", authorised: "yes" }));
    assert.throws(() => recipientSchema.parse({ email: "a@b.com", authorised: 1 }));

    assert.deepEqual(
      recipientSchema.parse({ email: "A@B.com", authorised: true }),
      { email: "a@b.com", authorised: true }
    );
  });
});

describe("suggestionResultSchema", () => {
  it("holds the model to the promised shape and trims to two keywords", () => {
    assert.throws(() => suggestionResultSchema.parse({ industry: "x", keywords: ["a"] }));
    assert.throws(() => suggestionResultSchema.parse({ keywords: ["a", "b"] }));

    /* The model is allowed to offer more; the form only has two fields. */
    assert.deepEqual(
      suggestionResultSchema.parse({
        industry: "Robotics",
        keywords: ["a", "b", "c", "d"]
      }),
      { industry: "Robotics", keywords: ["a", "b"] }
    );
  });
});

describe("readCookie", () => {
  const req = cookie => ({ headers: { cookie } });

  it("reads the named cookie out of the header", () => {
    assert.equal(readCookie(req("session=abc"), "session"), "abc");
    assert.equal(readCookie(req("a=1; session=abc; b=2"), "session"), "abc");
  });

  it("does not match on a prefix of another cookie's name", () => {
    assert.equal(readCookie(req("notsession=abc"), "session"), undefined);
  });

  it("returns undefined when there is no cookie header at all", () => {
    assert.equal(readCookie({ headers: {} }, "session"), undefined);
  });

  it("decodes percent-encoded values", () => {
    assert.equal(readCookie(req("session=a%20b"), "session"), "a b");
  });
});
