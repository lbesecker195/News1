import fs from "node:fs/promises";
import path from "node:path";

import puppeteer from "puppeteer";

import { pdfDir } from "../config/env.mjs";
import { isUUID } from "../utils/ids.mjs";

/*
 * The brief page, rendered to PDF by a real browser.
 *
 * This replaced a hand-rolled PDF 1.4 writer that set Helvetica on a blank
 * page. The page is now a designed thing — a hero card, a grid, colour — and
 * the only way to get that onto paper faithfully is to let Chromium lay it out
 * and print it. Puppeteer's bundled Chromium is used so the result does not
 * depend on whatever browser the host happens to have.
 *
 * The page is self-contained (no fonts, styles or scripts fetched over the
 * network), so setContent() is enough: nothing here needs the web server.
 *
 * One page, always. The layout is sized to fit a sheet, but headlines vary,
 * so the content is measured first and the print scaled down just enough to
 * fit when it would otherwise run over. A briefing that spills three lines
 * onto a second page reads as broken; one printed at 94% does not.
 */

/* Paper sizes in millimetres, matching the enum content.json accepts. */
const PAPER_MM = {
  A4: { width: 210, height: 297 },
  Letter: { width: 215.9, height: 279.4 },
  Legal: { width: 215.9, height: 355.6 }
};

const PX_PER = {
  mm: 96 / 25.4,
  cm: 96 / 2.54,
  in: 96,
  pt: 96 / 72
};

/* Below this the type is too small to read; better to let it run to page 2. */
export const MIN_SCALE = 0.6;

/* An idle browser is closed rather than held open between issues. */
const IDLE_MS = 15_000;

export function briefPdfPath(id) {
  if (!isUUID(id)) {
    throw new Error("A brief id must be a UUID.");
  }

  return path.join(pdfDir, `${id}.pdf`);
}

/*
 * The printable area in CSS pixels, which is what the page is laid out in.
 * Chromium prints at 96 px per inch.
 */
export function pageMetrics({ pageSize = "A4", margin = "16mm" } = {}) {
  const paper = PAPER_MM[pageSize] ?? PAPER_MM.A4;
  const parsed = String(margin).match(/^(\d+(?:\.\d+)?)(mm|cm|in|pt)$/);

  const marginPx = parsed
    ? Number(parsed[1]) * PX_PER[parsed[2]]
    : 16 * PX_PER.mm;

  const width = paper.width * PX_PER.mm;
  const height = paper.height * PX_PER.mm;

  return {
    width,
    height,
    marginPx,
    printableWidth: width - marginPx * 2,
    printableHeight: height - marginPx * 2
  };
}

/*
 * How far to shrink content of the given height so it fits the printable
 * height. Shrinking also widens the layout in CSS pixels, so lines wrap less
 * and the content gets shorter still — one measurement is therefore enough,
 * and errs on the side of fitting.
 */
export function fitScale(contentHeight, printableHeight, floor = MIN_SCALE) {
  if (!(contentHeight > 0) || !(printableHeight > 0)) return 1;

  return Math.max(floor, Math.min(1, printableHeight / contentHeight));
}

export async function htmlToPdf(html, {
  pageSize = "A4",
  margin = "16mm",
  onePage = true
} = {}) {
  const metrics = pageMetrics({ pageSize, margin });
  const page = await (await browser()).newPage();

  try {
    /*
     * Laid out at the width it will print at, under print media, so the
     * measured height is the height the printer will see.
     */
    await page.setViewport({
      width: Math.round(metrics.printableWidth),
      height: Math.round(metrics.printableHeight),
      deviceScaleFactor: 1
    });
    await page.emulateMediaType("print");
    await page.setContent(html, { waitUntil: "load" });

    let scale = 1;

    if (onePage) {
      const height = await page.evaluate(
        () => document.documentElement.scrollHeight
      );

      scale = fitScale(height, metrics.printableHeight);

      if (scale === MIN_SCALE) {
        console.warn(
          `Brief PDF: content ${Math.round(height)}px does not fit one page ` +
          `even at ${MIN_SCALE * 100}%; printing as is.`
        );
      }
    }

    return await page.pdf({
      /* The @page rule in the document carries size and margin. */
      preferCSSPageSize: true,
      printBackground: true,
      scale,
      ...(onePage && scale > MIN_SCALE ? { pageRanges: "1" } : {})
    });
  } finally {
    await page.close().catch(() => {});
    touch();
  }
}

export async function writeBriefPdf(id, html, print = {}) {
  const target = briefPdfPath(id);

  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.writeFile(target, await htmlToPdf(html, print));

  return target;
}

export async function deleteBriefPdf(id) {
  try {
    await fs.unlink(briefPdfPath(id));
    return true;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}

/* ---- browser lifecycle -------------------------------------------------- */

let launching = null;
let idle = null;

async function browser() {
  if (launching) {
    const current = await launching.catch(() => null);

    if (current?.connected) return current;
  }

  launching = puppeteer.launch({
    headless: true,
    /* Chromium refuses to sandbox when it is already root, as in a container. */
    args: process.getuid?.() === 0
      ? ["--no-sandbox", "--disable-setuid-sandbox"]
      : []
  });

  return launching;
}

/*
 * The browser is closed after a quiet spell so a worker that prints one brief
 * a day is not holding a Chromium open for the other 23 hours. The timer is
 * unref'd: it never keeps a process alive on its own.
 */
function touch() {
  clearTimeout(idle);
  idle = setTimeout(() => { closeBrowser().catch(() => {}); }, IDLE_MS);
  idle.unref?.();
}

export async function closeBrowser() {
  clearTimeout(idle);

  if (!launching) return;

  const pending = launching;

  launching = null;

  const current = await pending.catch(() => null);

  await current?.close().catch(() => {});
}
