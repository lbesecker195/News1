import { pool } from "../config/database.mjs";

/*
 * Returns true the first time an event id is seen and false for every retry,
 * so the caller applies an event's effects exactly once.
 */
export async function record({ id, kind, resourceId }) {
  const { rowCount } = await pool.query(
    `INSERT INTO paypal_events(id, kind, resource_id)
     VALUES($1,$2,$3)
     ON CONFLICT(id) DO NOTHING`,
    [id, kind, resourceId]
  );

  return rowCount > 0;
}

export async function prune(days = 90) {
  const { rowCount } = await pool.query(
    `DELETE FROM paypal_events
     WHERE received_at < now() - ($1 || ' days')::interval`,
    [String(days)]
  );

  return rowCount;
}
