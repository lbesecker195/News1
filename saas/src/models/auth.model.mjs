import { pool, transaction } from "../config/database.mjs";

/*
 * Signing in and signing up are the same act: the tenant row is created on
 * first sight of an email address, and the account only becomes real once the
 * link in the email is followed.
 */
export async function createLogin({ email, tokenHash, url }) {
  return transaction(async db => {
    const { rows } = await db.query(
      `INSERT INTO tenants(owner_email)
       VALUES($1)
       ON CONFLICT(owner_email)
       DO UPDATE SET owner_email=EXCLUDED.owner_email
       RETURNING id`,
      [email]
    );

    const tenantId = rows[0].id;

    await db.query(
      `INSERT INTO login_tokens(hash,tenant_id,expires_at)
       VALUES($1,$2,now()+interval '20 minutes')`,
      [tokenHash, tenantId]
    );

    await db.query(
      `INSERT INTO outbox(
         tenant_id,to_email,kind,payload,expires_at
       )
       VALUES($1,$2,'login',$3,now()+interval '20 minutes')`,
      [tenantId, email, JSON.stringify({ url })]
    );

    return tenantId;
  });
}

/*
 * The DELETE ... RETURNING is what makes the link single-use: two concurrent
 * requests race on the same row and only one gets a result back.
 */
export async function consumeLoginAndCreateSession({
  loginHash,
  sessionHash
}) {
  return transaction(async db => {
    const { rows } = await db.query(
      `DELETE FROM login_tokens
       WHERE hash=$1 AND expires_at>now()
       RETURNING tenant_id`,
      [loginHash]
    );

    if (!rows[0]) return null;

    await db.query(
      `INSERT INTO sessions(hash,tenant_id,expires_at)
       VALUES($1,$2,now()+interval '14 days')`,
      [sessionHash, rows[0].tenant_id]
    );

    return rows[0].tenant_id;
  });
}

export async function findTenantBySession(sessionHash) {
  const { rows } = await pool.query(
    `SELECT t.*
     FROM sessions s
     JOIN tenants t ON t.id=s.tenant_id
     WHERE s.hash=$1 AND s.expires_at>now()`,
    [sessionHash]
  );

  return rows[0] || null;
}

export async function deleteSession(sessionHash) {
  await pool.query(
    "DELETE FROM sessions WHERE hash=$1",
    [sessionHash]
  );
}
