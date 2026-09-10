-- Platform staff: the people who run the ad server.
--
-- Deliberately separate from tenants. A tenant signs in with an emailed link
-- and owns one company's newsletter; an admin holds a password and can see
-- every advertiser and campaign on the platform. Keeping the two in different
-- tables means a bug in one authentication path cannot grant the other's
-- access.
--
-- Idempotent. scripts/migrate.mjs wraps this in a transaction.

CREATE TABLE IF NOT EXISTS admins (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         citext      NOT NULL UNIQUE,
  -- scrypt, salted per row. Never the password itself.
  password_hash text        NOT NULL,
  active        boolean     NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_login_at timestamptz
);

CREATE TABLE IF NOT EXISTS admin_sessions (
  hash       text PRIMARY KEY,
  admin_id   uuid        NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS admin_sessions_expires_at_idx
  ON admin_sessions (expires_at);

-- A comped tenant has no PayPal subscription but is entitled to the service.
-- Recording why keeps "active with no subscription id" from looking like a bug
-- to whoever reads this table next.
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS comped_reason text;
