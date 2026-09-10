#!/usr/bin/env node
import { pool } from "../src/config/database.mjs";
import { requireEnv } from "../src/config/env.mjs";
import { APP } from "../src/services/platform.service.mjs";
import { buildCustomReport } from "../src/services/report.service.mjs";

/*
 * Builds a report for one reader, from what we know about their job.
 *
 *   npm run custom-report -- dana@acme.test
 *   npm run custom-report -- dana@acme.test --sections 5 --per-section 3
 *   npm run custom-report -- --title "VP Compliance" --company "Northgate Bank"
 *
 * The second form needs no contact row, which makes it the quick way to see
 * what a given job title would be sent before importing anybody.
 */
async function main() {
  requireEnv("databaseUrl", "openaiApiKey");

  const args = process.argv.slice(2);
  const email = args.find(arg => arg.includes("@") && !arg.startsWith("--"));

  const contact = email
    ? await lookup(email)
    : {
      name: value(args, "--name") ?? null,
      title: value(args, "--title") ?? null,
      company: value(args, "--company") ?? null,
      industry: value(args, "--industry") ?? null
    };

  if (!email && !contact.title && !contact.company) {
    throw new Error(
      "Give an email address, or --title and --company.\n" +
      'Example: npm run custom-report -- --title "VP Compliance" --company "Northgate Bank"'
    );
  }

  const language = value(args, "--language") ?? "en";

  const report = await buildCustomReport({
    contact,
    language,
    sectionCount: Number(value(args, "--sections") ?? 4),
    perSection: Number(value(args, "--per-section") ?? 2)
  });

  console.log(
    `\nReport for ${[contact.name, contact.title, contact.company]
      .filter(Boolean).join(", ") || "an unnamed reader"}\n`
  );

  for (const section of report.sections) {
    console.log(`  ${section.name.padEnd(14)}${section.why}`);
  }

  console.log(
    `\n  ${report.stories} stor${report.stories === 1 ? "y" : "ies"}` +
    `${report.personalised ? "" : "  (sections not ranked — defaults used)"}`
  );

  console.log(`\n  ${APP}/brief/${report.id}\n`);
}

async function lookup(email) {
  const { rows } = await pool.query(
    "SELECT id, name, title, company, industry FROM contacts WHERE email = $1",
    [email.trim().toLowerCase()]
  );

  if (!rows[0]) {
    throw new Error(
      `No contact with the address ${email}. ` +
      "Import them first, or pass --title and --company instead."
    );
  }

  return rows[0];
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
