import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { readingMinutes } from "../src/utils/reading-time.mjs";
import {
  LANGUAGE_NAMES,
  directionOf,
  languageName
} from "../src/utils/languages.mjs";

describe("readingMinutes", () => {
  it("estimates latin script by words", () => {
    assert.equal(readingMinutes("word ".repeat(220)), 1);
    assert.equal(readingMinutes("word ".repeat(1100)), 5);
  });

  it("estimates CJK by characters, not whitespace-separated words", () => {
    /*
     * Chinese prose has almost no spaces, so counting words would report a
     * long article as a one-minute read.
     */
    const chinese = "中".repeat(2500);

    assert.equal(chinese.split(/\s+/).length, 1, "one 'word' by whitespace");
    assert.equal(readingMinutes(chinese), 5);
  });

  it("does not count markdown syntax as reading", () => {
    const plain = "word ".repeat(220);
    const marked = `## Heading\n\n${"**word** ".repeat(220)}`;

    assert.equal(readingMinutes(marked), readingMinutes(plain));
  });

  it("never reports zero minutes for real text", () => {
    assert.equal(readingMinutes("a short line"), 1);
    assert.equal(readingMinutes(""), 0);
    assert.equal(readingMinutes(null), 0);
  });
});

describe("languages", () => {
  it("covers all twelve published languages", () => {
    assert.equal(Object.keys(LANGUAGE_NAMES).length, 12);
  });

  it("names each language as it names itself", () => {
    /* A reader scanning for their language recognises the endonym. */
    assert.equal(languageName("es"), "Español");
    assert.equal(languageName("zh"), "中文");
    assert.equal(languageName("ar"), "العربية");
    assert.equal(languageName("ur"), "اردو");
  });

  it("marks the right-to-left languages", () => {
    /*
     * Without this, Arabic and Urdu render ragged down the wrong edge — two of
     * twelve locales, and roughly 300 articles.
     */
    assert.equal(directionOf("ar"), "rtl");
    assert.equal(directionOf("ur"), "rtl");

    for (const code of ["en", "es", "fr", "de", "zh", "hi", "bn", "ru"]) {
      assert.equal(directionOf(code), "ltr", code);
    }
  });

  it("falls back rather than throwing on an unknown code", () => {
    assert.equal(languageName("xx"), "XX");
    assert.equal(directionOf("xx"), "ltr");
    assert.equal(directionOf(undefined), "ltr");
  });
});
