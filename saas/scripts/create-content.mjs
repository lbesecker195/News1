#!/usr/bin/env node
import { pool } from "../src/config/database.mjs";
import { requireEnv } from "../src/config/env.mjs";

import {
  CATEGORIES,
  TRANSLATION_CONCURRENCY,
  TRANSLATION_LANGUAGES,
  writeForCategory
} from "../src/services/editorial.service.mjs";

/*
 * Writes the journal: one article per section, in every language.
 *
 *   npm run create-content -- --dry-run          what it would publish
 *   npm run create-content                       every section, all languages
 *   npm run create-content -- --category AI      one section
 *   npm run create-content -- --languages es,fr  fewer translations
 *
 * Replaces the Hugo site's two scripts — the Python crawler that wrote each
 * section in English, and the Node script that translated it into eleven more
 * languages. Both now happen here, against the database.
 *
 * Cost is worth knowing before running it: one discovery call and one article
 * per section, plus one call per translation. Twelve sections in twelve
 * languages is 12 discoveries, 12 articles and 132 translations.
 *
 * Translations within a section run --concurrency at a time. Raise it if your
 * account allows and you are in a hurry; the ceiling is the rate limit, whose
 * backoff would undo the gain.
 */
async function main() {
  requireEnv("databaseUrl", "openaiApiKey", "tregToken");

  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");

  const only = value(args, "--category");
  const categories = only
    ? [match(only)].filter(Boolean)
    : CATEGORIES;

  if (only && !categories.length) {
    throw new Error(
      `Unknown section "${only}". One of: ${CATEGORIES.join(", ")}`
    );
  }

  const concurrency = Number(
    value(args, "--concurrency") ?? TRANSLATION_CONCURRENCY
  );

  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 12) {
    throw new Error("--concurrency must be a whole number between 1 and 12.");
  }

  const languages = value(args, "--languages")
    ?.split(",")
    .map(code => code.trim())
    .filter(Boolean) ?? TRANSLATION_LANGUAGES;

  console.log(
    `${dryRun ? "Dry run: " : ""}${categories.length} section(s), ` +
    `${languages.length + 1} language(s) each, ` +
    `${concurrency} translation(s) at a time\n`
  );

  const results = [];

  for (const category of categories) {
    const started = Date.now();
    const result = await writeForCategory({
      category,
      languages,
      concurrency,
      dryRun
    });

    result.seconds = Math.round((Date.now() - started) / 1000);

    results.push(result);
    console.log(`  ${line(result)}`);
  }

  const published = results.filter(r =>
    r.status === "published" || r.status === "would_publish");

  console.log(
    `\n${published.length}/${results.length} section(s) ` +
    `${dryRun ? "ready to publish" : "published"}`
  );

  const problems = results.filter(r =>
    !["published", "would_publish"].includes(r.status));

  if (problems.length) {
    console.log("\nNot published:");

    for (const problem of problems) {
      console.log(
        `  ${problem.category}: ${problem.status}` +
        (problem.attempts ? ` after ${problem.attempts} publisher(s)` : "") +
        (problem.phrase ? ` — "${problem.phrase}…"` : "")
      );

      if (problem.detail) console.log(`      ${problem.detail}`);
    }
  }
}

/*
 * One line per section, saying what happened and how close the writing came to
 * its source — the number worth watching over time.
 */
function line(result) {
  const label = result.category.padEnd(14);

  if (!["published", "would_publish"].includes(result.status)) {
    return `${label}${result.status}`;
  }

  return `${label}${String(result.languages.length).padStart(2)} langs  ` +
    `${String(result.seconds ?? 0).padStart(3)}s  ` +
    `verbatim:${String(result.verbatimRun ?? 0).padStart(2)}  ` +
    `${result.headline.slice(0, 40)}`;
}

const value = (args, flag) => {
  const index = args.indexOf(flag);

  return index === -1 ? undefined : args[index + 1];
};

const match = name => CATEGORIES.find(
  category => category.toLowerCase() === String(name).toLowerCase()
);

try {
  await main();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
