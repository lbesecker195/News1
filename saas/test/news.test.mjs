import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  mergeItems,
  plainQuery,
  publisherFrom
} from "../src/services/news.service.mjs";

describe("mergeItems", () => {
  const older = {
    id: "old",
    title: "Older",
    published: "2026-09-01T00:00:00.000Z"
  };

  const fresh = {
    id: "new",
    title: "Newer",
    published: "2026-09-09T00:00:00.000Z"
  };

  it("retains history so already-mailed links keep resolving", () => {
    const merged = mergeItems([older], [fresh]);

    assert.deepEqual(merged.map(item => item.id), ["new", "old"]);
  });

  it("lets a re-crawled item win over its stored copy", () => {
    const merged = mergeItems(
      [{ ...fresh, title: "Stale" }],
      [{ ...fresh, title: "Updated" }]
    );

    assert.equal(merged.length, 1);
    assert.equal(merged[0].title, "Updated");
  });

  it("caps the retained history", () => {
    const many = Array.from({ length: 90 }, (_, index) => ({
      id: `i${index}`,
      published: new Date(Date.now() - index * 1000).toISOString()
    }));

    assert.equal(mergeItems(many, []).length, 60);
  });

  it("tolerates a missing or malformed history column", () => {
    assert.deepEqual(mergeItems(null, [fresh]).map(i => i.id), ["new"]);
    assert.deepEqual(mergeItems(undefined, []), []);
  });
});

describe("plainQuery", () => {
  it("strips Google boolean syntax for a neural search", () => {
    assert.equal(
      plainQuery('"Industrial robotics" OR "warehouse automation" OR "grippers"'),
      "Industrial robotics warehouse automation grippers"
    );
  });

  it("leaves an already-plain query alone", () => {
    assert.equal(plainQuery("industrial robotics"), "industrial robotics");
  });

  it("does not strip OR inside a word", () => {
    assert.equal(plainQuery('"ORthopedic implants"'), "ORthopedic implants");
  });

  it("handles nothing without throwing", () => {
    assert.equal(plainQuery(""), "");
    assert.equal(plainQuery(null), "");
  });
});

describe("publisherFrom", () => {
  it("names the publisher by host, dropping www", () => {
    assert.equal(publisherFrom("https://www.example.com/a/b"), "example.com");
    assert.equal(publisherFrom("https://news.example.co.uk/a"), "news.example.co.uk");
  });

  it("falls back rather than throwing on junk", () => {
    assert.equal(publisherFrom("not a url"), "Unknown");
    assert.equal(publisherFrom(null), "Unknown");
  });
});
