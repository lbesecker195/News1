#!/usr/bin/env node
import { pool } from "../src/config/database.mjs";
import { requireEnv } from "../src/config/env.mjs";
import * as admins from "../src/models/admin.model.mjs";
import * as subscribers from "../src/models/subscriber.model.mjs";
import { transaction } from "../src/config/database.mjs";

/*
 * Creates or updates a platform administrator, and optionally comps that
 * address a working tenant so staff can use the product they are running.
 *
 *   npm run create-admin -- me@example.com 'a long password' --comp
 *
 * The password is read from argv, so it will be in your shell history. Change
 * it from the admin page afterwards, or pass it via ADMIN_PASSWORD instead.
 */
async function main() {
  requireEnv("databaseUrl");

  const args = process.argv.slice(2).filter(a => !a.startsWith("--"));
  const comp = process.argv.includes("--comp");

  const email = String(args[0] ?? "").trim().toLowerCase();
  const password = args[1] ?? process.env.ADMIN_PASSWORD ?? "";

  if (!email || !password) {
    throw new Error(
      "Usage: npm run create-admin -- <email> <password> [--comp]"
    );
  }

  const admin = await admins.upsert({ email, password });

  console.log(
    `${admin.created ? "Created" : "Updated"} admin ${admin.email}`
  );

  if (!comp) return;

  /*
   * A comped tenant is active with no PayPal subscription behind it. The
   * reason is recorded so the row does not read as a billing bug later.
   */
  const { rows } = await pool.query(
    `INSERT INTO tenants(owner_email, billing_status, comped_reason)
     VALUES($1,'active','platform staff account')
     ON CONFLICT(owner_email) DO UPDATE
       SET billing_status = 'active',
           comped_reason = 'platform staff account'
     RETURNING id, owner_email`,
    [email]
  );

  const tenant = rows[0];

  /* Staff are stakeholder one of their own tenant, exactly like a customer. */
  await transaction(db =>
    subscribers.enrolOwner(db, tenant.id, tenant.owner_email));

  console.log(
    `Comped tenant for ${tenant.owner_email} — active, no subscription needed.`
  );
}

try {
  await main();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}
