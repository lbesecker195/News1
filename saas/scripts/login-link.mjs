#!/usr/bin/env node
import { pool } from "../src/config/database.mjs";
import { requireEnv } from "../src/config/env.mjs";
import * as auth from "../src/models/auth.model.mjs";
import { APP, hash, token } from "../src/services/platform.service.mjs";

/*
 * Prints the sign-in link that would have been emailed.
 *
 * Rnews1 has no passwords, so with mail unconfigured there is otherwise no way
 * to get past the sign-in page. Everything about the flow is real except the
 * delivery: the link below is the one the outbox holds, it expires in 20
 * minutes, and it still only works once.
 *
 *   npm run login                 the most recent link queued, however it was
 *                                 requested — use the web form, then run this
 *   npm run login -- me@you.com   issue a fresh one for that address
 *
 * Never wire this into the app. It exists because a developer already has the
 * database; it hands out sessions to anyone who can run it.
 */
async function main() {
  requireEnv("databaseUrl");

  const email = process.argv.slice(2).find(arg => arg.includes("@"));

  if (email) {
    const secret = token();

    await auth.createLogin({
      email: email.trim().toLowerCase(),
      tokenHash: hash(secret),
      url: `${APP}/login/${secret}`
    });

    console.log(`\nIssued for ${email}:\n\n  ${APP}/login/${secret}\n`);
    return;
  }

  /*
   * No address given: show what is already waiting. This is the one that
   * tests the real path — request a link in the browser, then read it here.
   */
  const { rows } = await pool.query(
    `SELECT o.to_email, o.payload->>'url' AS url, o.status, o.created_at,
            o.expires_at < now() AS expired
     FROM outbox o
     WHERE o.kind = 'login'
     ORDER BY o.created_at DESC
     LIMIT 5`
  );

  if (!rows.length) {
    console.log(
      "\nNo sign-in links queued. Request one at " +
      `${APP}/login, or run: npm run login -- you@example.com\n`
    );
    return;
  }

  console.log("\nMost recent sign-in links:\n");

  for (const row of rows) {
    const state = row.expired
      ? "expired"
      : row.status === "pending"
        ? "unsent (mail not configured)"
        : row.status;

    console.log(`  ${row.to_email}  ·  ${state}`);
    console.log(`  ${row.expired ? "(expired) " : ""}${row.url}\n`);
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
