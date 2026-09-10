import "./helpers/env.mjs";

import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { after, describe, it } from "node:test";

import {
  MIN_SCALE,
  briefPdfPath,
  closeBrowser,
  deleteBriefPdf,
  fitScale,
  htmlToPdf,
  pageMetrics,
  writeBriefPdf
} from "../src/services/pdf.service.mjs";

const ID = "550e8400-e29b-41d4-a716-446655440000";

describe("pageMetrics", () => {
  it("measures the printable area in CSS pixels", () => {
    const a4 = pageMetrics({ pageSize: "A4", margin: "16mm" });

    /* 297mm − 32mm at 96dpi. */
    assert.ok(Math.abs(a4.printableHeight - 1001.6) < 1, a4.printableHeight);
    assert.ok(Math.abs(a4.printableWidth - 672.8) < 1, a4.printableWidth);

    const letter = pageMetrics({ pageSize: "Letter", margin: "0.5in" });

    assert.ok(Math.abs(letter.printableHeight - 960) < 1, letter.printableHeight);
  });

  it("falls back rather than failing on a margin it cannot read", () => {
    assert.ok(pageMetrics({ margin: "wide" }).marginPx > 0);
    assert.ok(pageMetrics({ pageSize: "Tabloid" }).height > 0);
  });
});

describe("fitScale", () => {
  it("leaves content that fits alone", () => {
    assert.equal(fitScale(800, 1000), 1);
    assert.equal(fitScale(1000, 1000), 1);
  });

  it("shrinks just enough to fit one page", () => {
    assert.equal(fitScale(1250, 1000), 0.8);
  });

  it("stops at the floor rather than printing unreadably small", () => {
    assert.equal(fitScale(5000, 1000), MIN_SCALE);
  });

  it("copes with a page that measured nothing", () => {
    assert.equal(fitScale(0, 1000), 1);
    assert.equal(fitScale(NaN, 1000), 1);
  });
});

describe("rendering", () => {
  after(async () => {
    await deleteBriefPdf(ID).catch(() => {});
    await closeBrowser();
  });

  it("refuses an id that is not a UUID, so it cannot escape the data dir", () => {
    assert.throws(() => briefPdfPath("../../etc/passwd"), /UUID/);
    assert.throws(() => briefPdfPath("a/b"), /UUID/);
  });

  it("prints a linked, single page from self-contained HTML", async () => {
    const html = `<!doctype html><html><head><style>
        @page { size: A4; margin: 16mm }
        body { font: 14px serif }
      </style></head><body>
        <a href="https://example.com/story">A headline that is a link</a>
        ${"<p>A paragraph of the briefing.</p>".repeat(30)}
      </body></html>`;

    const pdf = await htmlToPdf(html, { pageSize: "A4", margin: "16mm" });
    const text = pdf.toString("latin1");

    assert.ok(text.startsWith("%PDF-"), "is a PDF");
    assert.match(text, /\/Count 1\b/, "one page");
    assert.ok(text.includes("/URI (https://example.com/story)"), "links survive");
  });

  it("scales a long page down to one sheet instead of spilling", async () => {
    const html = `<!doctype html><html><head><style>
        @page { size: A4; margin: 16mm }
        p { margin: 0; font: 16px/1.5 serif }
      </style></head><body>
        ${"<p>Line.</p>".repeat(60)}
      </body></html>`;

    /* 60 lines × 24px = 1440px, against ~1000px printable: about 70%. */
    const one = await htmlToPdf(html, { pageSize: "A4", margin: "16mm" });
    assert.match(one.toString("latin1"), /\/Count 1\b/);

    const many = await htmlToPdf(html, {
      pageSize: "A4",
      margin: "16mm",
      onePage: false
    });
    assert.match(many.toString("latin1"), /\/Count 2\b/, "unscaled it runs over");
  });

  it("writes the file where /pdf/:id will look for it", async () => {
    const file = await writeBriefPdf(
      ID,
      "<!doctype html><html><body><p>hello</p></body></html>",
      { pageSize: "Letter", margin: "12mm" }
    );

    assert.equal(file, briefPdfPath(ID));

    const stat = await fs.stat(file);

    assert.ok(stat.size > 1000);
  });
});
