#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";

import { pool } from "../src/config/database.mjs";
import { ROOT, requireEnv } from "../src/config/env.mjs";

/*
 * Applies every migrations/*.sql file in name order, once. Each file is run
 * inside its own transaction alongside the bookkeeping insert, so a failure
 * leaves nothing half-applied.
 */
async function main() {
  requireEnv("databaseUrl");

  await pool.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      name       text PRIMARY KEY,
      applied_at timestamptz NOT NULL DEFAULT now()
    )
  `);

  const directory = path.join(ROOT, "migrations");

  const files = (await fs.readdir(directory))
    .filter(name => name.endsWith(".sql"))
    .sort();

  const { rows } = await pool.query("SELECT name FROM schema_migrations");
  const applied = new Set(rows.map(row => row.name));

  for (const name of files) {
    if (applied.has(name)) {
      console.log(`= ${name}`);
      continue;
    }

    const sql = await fs.readFile(path.join(directory, name), "utf8");
    const client = await pool.connect();

    try {
      await client.query("BEGIN");
      await client.query(sql);
      await client.query(
        "INSERT INTO schema_migrations(name) VALUES($1)",
        [name]
      );
      await client.query("COMMIT");
      console.log(`+ ${name}`);
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw new Error(`${name}: ${error.message}`);
    } finally {
      client.release();
    }
  }
}

try {
  await main();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
