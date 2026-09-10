#!/usr/bin/env node
import fs from "node:fs/promises";

import { pool } from "../src/config/database.mjs";
import { requireEnv } from "../src/config/env.mjs";
import { contactImportSchema } from "../src/utils/validation.mjs";

/*
 * Imports an authorised contact export into the contacts table.
 *
 *   npm run import -- ./contacts.json
 *   npm run import -- ./contacts.json --dry-run
 *
 * Accepts either a bare array or { source, contacts: [...] }. Every record
 * needs an email; name, company, title and source are optional.
 *
 * Suppression protections, in order:
 *   - an address that has opted out or hard bounced is never revived, and its
 *     details are not refreshed either;
 *   - existing rows are only filled in where a field is currently empty, so an
 *     import can never overwrite better data with worse;
 *   - importing does not subscribe anyone to anything. Contacts become
 *     recipients only by confirming an invitation.
 */

async function main() {
  requireEnv("databaseUrl");

  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const file = args.find(value => !value.startsWith("--"));

  if (!file) {
    throw new Error(
      "Usage: npm run import -- ./contacts.json [--dry-run]"
    );
  }

  const parsed = JSON.parse(await fs.readFile(file, "utf8"));

  const records = Array.isArray(parsed)
    ? parsed
    : Array.isArray(parsed?.contacts)
      ? parsed.contacts
      : null;

  if (!records) {
    throw new Error(
      "Expected a JSON array, or an object with a contacts array."
    );
  }

  const defaultSource = typeof parsed?.source === "string"
    ? parsed.source
    : null;

  const seen = new Set();
  const valid = [];
  const rejected = [];

  for (const [index, record] of records.entries()) {
    const result = contactImportSchema.safeParse({
      ...record,
      source: record?.source ?? defaultSource ?? undefined
    });

    if (!result.success) {
      rejected.push({
        index,
        email: record?.email ?? null,
        reason: result.error.issues[0]?.message ?? "invalid record"
      });
      continue;
    }

    if (seen.has(result.data.email)) continue;

    seen.add(result.data.email);
    valid.push(result.data);
  }

  const summary = {
    file,
    records: records.length,
    valid: valid.length,
    duplicates: records.length - valid.length - rejected.length,
    rejected: rejected.length,
    inserted: 0,
    existing: 0,
    suppressed: 0
  };

  if (dryRun) {
    console.log({ ...summary, dryRun: true, rejected });
    return summary;
  }

  for (const contact of valid) {
    const { rows } = await pool.query(
      `INSERT INTO contacts(email, name, company, title, source)
       VALUES($1,$2,$3,$4,$5)
       ON CONFLICT(email) DO UPDATE SET
         name    = COALESCE(contacts.name, EXCLUDED.name),
         company = COALESCE(contacts.company, EXCLUDED.company),
         title   = COALESCE(contacts.title, EXCLUDED.title),
         source  = COALESCE(contacts.source, EXCLUDED.source)
       WHERE contacts.opted_out_at IS NULL
         AND contacts.bounced_at IS NULL
       RETURNING (xmax = 0) AS inserted`,
      [
        contact.email,
        contact.name ?? null,
        contact.company ?? null,
        contact.title ?? null,
        contact.source ?? null
      ]
    );

    /*
     * No row comes back when the DO UPDATE guard rejected the conflict, which
     * means the address is suppressed and must be left exactly as it is.
     */
    if (!rows[0]) {
      summary.suppressed++;
    } else if (rows[0].inserted) {
      summary.inserted++;
    } else {
      summary.existing++;
    }
  }

  console.log(summary);

  if (rejected.length) {
    console.log(`Rejected ${rejected.length} record(s):`);

    for (const entry of rejected.slice(0, 20)) {
      console.log(`  [${entry.index}] ${entry.email ?? "(no email)"} — ${entry.reason}`);
    }

    if (rejected.length > 20) {
      console.log(`  ... and ${rejected.length - 20} more`);
    }
  }

  return summary;
}

try {
  await main();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
