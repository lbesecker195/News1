-- Rnews1 initial schema.
-- Idempotent: safe to re-run against an existing database.
--
-- No BEGIN/COMMIT here: scripts/migrate.mjs wraps each file in its own
-- transaction. Applying by hand? Use psql -1 so it is still atomic.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

-- ---------------------------------------------------------------------------
-- Topics: one shared, de-duplicated news query per (language, keyword set).
-- Several tenants with identical interests share a single crawl.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS topics (
  key           text PRIMARY KEY,
  query         text        NOT NULL,
  language      text        NOT NULL DEFAULT 'en',
  items         jsonb       NOT NULL DEFAULT '[]'::jsonb,
  refreshed_at  timestamptz,
  refresh_after timestamptz NOT NULL DEFAULT now(),
  last_error    text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS topics_refresh_after_idx
  ON topics (refresh_after);

-- ---------------------------------------------------------------------------
-- Tenants: one paying company.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tenants (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_email     citext      NOT NULL UNIQUE,
  name            text,
  domain          text,
  industry        text,
  keywords        jsonb       NOT NULL DEFAULT '[]'::jsonb,
  language        text        NOT NULL DEFAULT 'en',
  topic_key       text        REFERENCES topics(key) ON DELETE SET NULL,
  public_token    uuid        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  -- PayPal subscription id (I-XXXXXXXXXXXX). Unique: one live subscription per
  -- tenant, and a subscription can never be claimed by a second tenant.
  paypal_subscription_id text UNIQUE,
  billing_status  text        NOT NULL DEFAULT 'inactive',
  digest_sent_on  date,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS tenants_topic_key_idx ON tenants (topic_key);
CREATE INDEX IF NOT EXISTS tenants_billing_status_idx ON tenants (billing_status);

-- ---------------------------------------------------------------------------
-- PayPal billing plans.
--
-- PayPal models a recurring price as a product plus a plan, both created once
-- and referenced by id afterwards. The row is keyed on the price, so changing
-- the price creates a new plan rather than silently billing the old amount, and
-- existing subscribers stay on the plan they agreed to.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS paypal_plans (
  key          text PRIMARY KEY,
  product_id   text        NOT NULL,
  plan_id      text        NOT NULL,
  amount_cents int         NOT NULL,
  raw          jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Authentication: single-use email links, then long-lived sessions.
-- Only SHA-256 hashes of the secrets are stored.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS login_tokens (
  hash       text PRIMARY KEY,
  tenant_id  uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS login_tokens_expires_at_idx
  ON login_tokens (expires_at);

CREATE TABLE IF NOT EXISTS sessions (
  hash       text PRIMARY KEY,
  tenant_id  uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sessions_expires_at_idx ON sessions (expires_at);

-- ---------------------------------------------------------------------------
-- Contacts: one row per email address across the whole platform, so that a
-- suppression (opt-out or hard bounce) applies everywhere at once.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS contacts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email        citext      NOT NULL UNIQUE,
  name         text,
  company      text,
  title        text,
  source       text,
  unsub_token  uuid        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  opted_out_at timestamptz,
  bounced_at   timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Subscribers: a contact's confirmed opt-in to one tenant's digest.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS subscribers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  contact_id         uuid        NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  state              text        NOT NULL DEFAULT 'pending',
  confirm_token      uuid        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  confirm_expires_at timestamptz NOT NULL DEFAULT now() + interval '7 days',
  confirmed_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT subscribers_tenant_contact_key UNIQUE (tenant_id, contact_id),
  CONSTRAINT subscribers_state_check
    CHECK (state IN ('pending', 'active', 'unsubscribed'))
);

CREATE INDEX IF NOT EXISTS subscribers_tenant_state_idx
  ON subscribers (tenant_id, state);

-- ---------------------------------------------------------------------------
-- Outbox: every outgoing email, claimed one at a time by the delivery loop.
--
-- status transitions
--   pending    -> processing -> accepted   (Mailgun took the message)
--                            -> unknown    (send result undetermined; never
--                                           retried, resolved by webhook)
--                            -> failed     (permanent, or attempts exhausted)
--                            -> pending    (transient failure, backed off)
--   pending    -> suppressed  (recipient opted out or bounced)
--   pending    -> expired     (not sent before expires_at)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS outbox (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        REFERENCES tenants(id) ON DELETE CASCADE,
  contact_id          uuid        REFERENCES contacts(id) ON DELETE CASCADE,
  to_email            citext      NOT NULL,
  kind                text        NOT NULL,
  payload             jsonb       NOT NULL DEFAULT '{}'::jsonb,
  status              text        NOT NULL DEFAULT 'pending',
  attempts            int         NOT NULL DEFAULT 0,
  run_after           timestamptz NOT NULL DEFAULT now(),
  expires_at          timestamptz,
  locked_at           timestamptz,
  provider_message_id text,
  last_error          text,
  dedupe_key          text        UNIQUE,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT outbox_kind_check
    CHECK (kind IN ('login', 'confirmation', 'digest', 'campaign')),
  CONSTRAINT outbox_status_check
    CHECK (status IN ('pending', 'processing', 'accepted', 'unknown',
                      'failed', 'suppressed', 'expired'))
);

-- Partial index: the delivery loop only ever scans claimable rows.
CREATE INDEX IF NOT EXISTS outbox_claimable_idx
  ON outbox (run_after)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS outbox_stuck_idx
  ON outbox (locked_at)
  WHERE status = 'processing';

CREATE INDEX IF NOT EXISTS outbox_contact_idx ON outbox (contact_id);

-- ---------------------------------------------------------------------------
-- Briefs: the rendered daily document behind /brief/:id and /pdf/:id.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS briefs (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  html       text        NOT NULL,
  has_pdf    boolean     NOT NULL DEFAULT false,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '30 days',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS briefs_expires_at_idx ON briefs (expires_at);

-- ---------------------------------------------------------------------------
-- Mailgun events: the id column doubles as the idempotency key, so a
-- redelivered webhook applies its side effects exactly once.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mailgun_events (
  id          text PRIMARY KEY,
  kind        text        NOT NULL,
  -- Deliberately not a foreign key: an event can arrive after maintenance has
  -- pruned the outbox row it refers to, and losing the event is worse than
  -- keeping a dangling id.
  job_id      uuid,
  received_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mailgun_events_received_at_idx
  ON mailgun_events (received_at);

-- ---------------------------------------------------------------------------
-- PayPal webhook events. As with Mailgun, the id is the idempotency key: PayPal
-- retries deliveries, and a retry must not apply its effects a second time.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS paypal_events (
  id          text PRIMARY KEY,
  kind        text        NOT NULL,
  resource_id text,
  received_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS paypal_events_received_at_idx
  ON paypal_events (received_at);
