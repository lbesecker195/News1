import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { firstSentence } from "../src/utils/teaser.mjs";

describe("firstSentence", () => {
  it("keeps the first sentence and trails off", () => {
    assert.equal(
      firstSentence("Rates rose again. Analysts expect more."),
      "Rates rose again…"
    );
  });

  it("does not break on an abbreviation", () => {
    assert.equal(
      firstSentence("U.S. regulators moved first. Europe followed."),
      "U.S. regulators moved first…"
    );
  });

  it("uses the whole text when there is no full stop", () => {
    assert.equal(firstSentence("A headline with no ending"), "A headline with no ending…");
  });

  it("cuts a long sentence at a word boundary", () => {
    const long = "word ".repeat(60).trim() + ".";
    const teaser = firstSentence(long, 50);

    assert.ok(teaser.length <= 51, teaser);
    assert.ok(teaser.endsWith("…"));
    assert.ok(!teaser.includes("  "));
  });

  it("does not double up punctuation before the ellipsis", () => {
    assert.equal(firstSentence("Really?! Yes."), "Really…");
    assert.equal(firstSentence("Trailing already…"), "Trailing already…");
  });

  it("collapses whitespace and handles nothing", () => {
    assert.equal(firstSentence("  spaced   out.  "), "spaced out…");
    assert.equal(firstSentence(""), "");
    assert.equal(firstSentence(null), "");
  });
});
