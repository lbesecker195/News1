import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { MIN_LENGTH, hashPassword, verifyPassword } from "../src/utils/password.mjs";

describe("password hashing", () => {
  it("never stores the password itself", async () => {
    const stored = await hashPassword("correct horse battery");

    assert.ok(!stored.includes("correct horse battery"));
    assert.match(stored, /^scrypt\$16384\$8\$1\$[0-9a-f]{32}\$[0-9a-f]{128}$/);
  });

  it("salts, so the same password hashes differently every time", async () => {
    const a = await hashPassword("the same password");
    const b = await hashPassword("the same password");

    assert.notEqual(a, b);
    assert.ok(await verifyPassword("the same password", a));
    assert.ok(await verifyPassword("the same password", b));
  });

  it("verifies the right password and rejects everything else", async () => {
    const stored = await hashPassword("a good password");

    assert.equal(await verifyPassword("a good password", stored), true);
    assert.equal(await verifyPassword("a good passwordX", stored), false);
    assert.equal(await verifyPassword("A GOOD PASSWORD", stored), false);
    assert.equal(await verifyPassword("", stored), false);
  });

  it("returns false rather than throwing on a corrupt stored value", async () => {
    for (const stored of [
      "nonsense",
      "scrypt$",
      "scrypt$16384$8$1$zz$zz",
      "bcrypt$16384$8$1$aa$bb",
      "",
      null,
      undefined
    ]) {
      assert.equal(
        await verifyPassword("anything", stored),
        false,
        String(stored)
      );
    }
  });

  it("refuses to hash a password below the minimum length", async () => {
    await assert.rejects(
      () => hashPassword("x".repeat(MIN_LENGTH - 1)),
      /at least/
    );

    await assert.doesNotReject(() => hashPassword("x".repeat(MIN_LENGTH)));
  });
});
