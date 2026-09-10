#!/usr/bin/env node
import { pool } from "../src/config/database.mjs";
import { requireEnv } from "../src/config/env.mjs";

import * as briefs from "../src/models/brief.model.mjs";
import { renderBriefPage } from "../src/services/brief-page.service.mjs";
import { closeBrowser, writeBriefPdf } from "../src/services/pdf.service.mjs";

/*
 * Prints a brief to PDF with the same renderer the site uses.
 *
 *   npm run pdf -- <brief-id>
 *   npm run pdf -- <brief-id> --out ~/Desktop/briefing.pdf
 *
 * Without --out the file lands in DATA_DIR/pdfs and /pdf/:id serves it.
 */
async function main() {
  requireEnv("databaseUrl");

  const args = process.argv.slice(2);
  const id = args.find(arg => !arg.startsWith("--"));
  const out = args[args.indexOf("--out") + 1];

  if (!id) {
    throw new Error("Usage: npm run pdf -- <brief-id> [--out file.pdf]");
  }

  const record = await briefs.findUnexpired(id);

  if (!record) {
    throw new Error(`No unexpired brief with id ${id}.`);
  }

  const { html, content, model } = await renderBriefPage(record);

  let file;

  if (args.includes("--out") && out) {
    const { htmlToPdf } = await import("../src/services/pdf.service.mjs");
    const fs = await import("node:fs/promises");

    await fs.writeFile(out, await htmlToPdf(html, content.print));
    file = out;
  } else {
    file = await writeBriefPdf(id, html, content.print);
    await briefs.markPdfWritten(id);
  }

  console.log(
    `${model.stories.length} stor${model.stories.length === 1 ? "y" : "ies"}, ` +
    `${content.print.pageSize} → ${file}`
  );
}

try {
  await main();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await closeBrowser();
  await pool.end();
}
