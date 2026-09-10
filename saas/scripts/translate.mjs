#!/usr/bin/env node
import { pool } from "../src/config/database.mjs";
import { requireEnv } from "../src/config/env.mjs";

import {
  TRANSLATION_CONCURRENCY,
  backfillTranslations
} from "../src/services/editorial.service.mjs";
import { LANGUAGE_NAMES } from "../src/utils/languages.mjs";

/*
 * Fills in the archive's missing translations.
 *
 *   npm run translate -- --dry-run        what is missing, and from where
 *   npm run translate                     translate up to 25 articles
 *   npm run translate -- --limit 200      work through more of the backlog
 *   npm run translate -- --languages es,fr  only these locales
 *
 * Replaces the Hugo site's translate-content.mjs. Safe to run repeatedly: it
 * only ever adds a language an article does not already have, and it stops
 * being useful — rather than doing damage — once the archive is complete.
 *
 * One model call per missing language, so `--dry-run` first is worth the ten
 * seconds it takes.
 */
async function main() {
  requireEnv("databaseUrl", "openaiApiKey");

  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");

  const languages = value(args, "--languages")
    ?.split(",")
    .map(code => code.trim())
    .filter(Boolean) ?? Object.keys(LANGUAGE_NAMES);

  const limit = Number(value(args, "--limit") ?? 25);

  if (!Number.isInteger(limit) || limit < 1) {
    throw new Error("--limit must be a positive whole number.");
  }

  const unknown = languages.filter(code => !LANGUAGE_NAMES[code]);

  if (unknown.length) {
    throw new Error(
      `Unknown language(s): ${unknown.join(", ")}. ` +
      `One of: ${Object.keys(LANGUAGE_NAMES).join(", ")}`
    );
  }

  const concurrency = Number(
    value(args, "--concurrency") ?? TRANSLATION_CONCURRENCY
  );

  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 12) {
    throw new Error("--concurrency must be a whole number between 1 and 12.");
  }

  const results = await backfillTranslations({
    languages,
    limit,
    concurrency,
    dryRun
  });

  if (!results.length) {
    console.log(
      `\nNothing missing: every article is in all ${languages.length} languages.\n`
    );

    return;
  }

  console.log(
    `\n${dryRun ? "Would translate" : "Translated"} ` +
    `${results.length} article(s):\n`
  );

  let added = 0;
  let failed = 0;

  for (const result of results) {
    const gaps = result.missing ?? [...result.added ?? [], ...result.failed ?? []];

    added += result.added?.length ?? 0;
    failed += result.failed?.length ?? 0;

    console.log(
      `  ${String(result.status).padEnd(16)}` +
      `${String(gaps.length).padStart(2)} locale(s)  ` +
      `${(result.key ?? "").slice(0, 44)}`
    );

    if (result.failed?.length) {
      console.log(`      failed: ${result.failed.join(", ")}`);
    }
  }

  console.log(
    dryRun
      ? `\n${results.reduce((n, r) => n + (r.missing?.length ?? 0), 0)} ` +
        "locale(s) would be written.\n"
      : `\n${added} locale(s) written` +
        (failed ? `, ${failed} failed — run again to retry them` : "") + ".\n"
  );
}

const value = (args, flag) => {
  const index = args.indexOf(flag);

  return index === -1 ? undefined : args[index + 1];
};

try {
  await main();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
