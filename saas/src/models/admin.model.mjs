import { pool } from "../config/database.mjs";

import { hashPassword, verifyPassword } from "../utils/password.mjs";

export async function upsert({ email, password }) {
  const passwordHash = await hashPassword(password);

  const { rows } = await pool.query(
    `INSERT INTO admins(email, password_hash)
     VALUES($1,$2)
     ON CONFLICT(email) DO UPDATE
       SET password_hash = EXCLUDED.password_hash, active = true
     RETURNING id, email, (xmax = 0) AS created`,
    [email, passwordHash]
  );

  return rows[0];
}

/*
 * Verifies a sign-in. Returns null for an unknown email, a deactivated account
 * or a wrong password without distinguishing between them — an attacker should
 * not be able to enumerate which admin addresses exist.
 */
export async function authenticate(email, password) {
  const { rows } = await pool.query(
    "SELECT * FROM admins WHERE email = $1 AND active",
    [email]
  );

  const admin = rows[0];

  /*
   * A hash is verified even when no account matched, so a missing account and
   * a wrong password take the same time to answer.
   */
  const stored = admin?.password_hash ??
    "scrypt$16384$8$1$00$00";

  const correct = await verifyPassword(password, stored);

  if (!admin || !correct) return null;

  await pool.query(
    "UPDATE admins SET last_login_at = now() WHERE id = $1",
    [admin.id]
  );

  return { id: admin.id, email: admin.email };
}

export async function createSession(hash, adminId) {
  await pool.query(
    `INSERT INTO admin_sessions(hash, admin_id, expires_at)
     VALUES($1,$2,now() + interval '12 hours')`,
    [hash, adminId]
  );
}

export async function findBySession(hash) {
  const { rows } = await pool.query(
    `SELECT a.id, a.email
     FROM admin_sessions s
     JOIN admins a ON a.id = s.admin_id
     WHERE s.hash = $1 AND s.expires_at > now() AND a.active`,
    [hash]
  );

  return rows[0] ?? null;
}

export async function deleteSession(hash) {
  await pool.query("DELETE FROM admin_sessions WHERE hash = $1", [hash]);
}

export async function pruneSessions() {
  await pool.query("DELETE FROM admin_sessions WHERE expires_at <= now()");
}
