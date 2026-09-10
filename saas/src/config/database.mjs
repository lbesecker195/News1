import pg from "pg";

import { env } from "./env.mjs";

export const pool = new pg.Pool({
  connectionString: env.databaseUrl,
  max: 10,
  /*
   * A runaway query must not pin a pool slot forever. The ceiling is generous
   * because billing writes wait on PayPal round trips inside a transaction.
   */
  statement_timeout: 30_000,
  application_name: "rnews1"
});

/*
 * An idle pool client that the database has already dropped surfaces here, not
 * on a query. Without a listener this is an unhandled 'error' event and the
 * process dies.
 */
pool.on("error", error => {
  console.error("Idle Postgres client error:", error);
});

export async function transaction(fn) {
  const client = await pool.connect();

  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    /*
     * A failed ROLLBACK (dead connection, for instance) must not mask the
     * original error, which is what the caller actually needs to see.
     */
    try {
      await client.query("ROLLBACK");
    } catch (rollbackError) {
      console.error("Rollback failed:", rollbackError);
    }

    throw error;
  } finally {
    client.release();
  }
}
