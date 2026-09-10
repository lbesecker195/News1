import { pool } from "../config/database.mjs";

export async function findByKey(key) {
  const { rows } = await pool.query(
    "SELECT * FROM paypal_plans WHERE key=$1",
    [key]
  );

  return rows[0] || null;
}

/*
 * ON CONFLICT rather than a plain insert: two processes can create the plan at
 * PayPal concurrently on a cold database, and the first row to land wins. The
 * loser's PayPal plan is simply never referenced.
 */
export async function create({ key, productId, planId, amountCents, raw }) {
  const { rows } = await pool.query(
    `INSERT INTO paypal_plans(key, product_id, plan_id, amount_cents, raw)
     VALUES($1,$2,$3,$4,$5)
     ON CONFLICT(key) DO UPDATE SET key=EXCLUDED.key
     RETURNING *`,
    [key, productId, planId, amountCents, JSON.stringify(raw ?? {})]
  );

  return rows[0];
}
