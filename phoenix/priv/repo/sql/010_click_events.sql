-- What gets clicked.
--
-- Deliberately not analytics about people: no identifier, no cookie, no IP,
-- nothing that survives the request. A row says which page on which host had
-- which link or button clicked, and when. That answers "is anyone clicking
-- the hero card" and "which sections do readers leave through" without
-- building a profile of anybody, which matters for a product whose whole
-- legal position is that it is B2B and does not track individuals.

CREATE TABLE IF NOT EXISTS click_events (
  id          bigserial   PRIMARY KEY,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  -- The tenant whose site it happened on; NULL on the app and the archive.
  tenant_id   uuid        REFERENCES tenants(id) ON DELETE SET NULL,
  host        text        NOT NULL,
  path        text        NOT NULL,
  kind        text        NOT NULL,
  target      text,
  label       text,
  external    boolean     NOT NULL DEFAULT false,
  language    text,
  CONSTRAINT click_events_kind_check CHECK (kind IN ('link', 'button'))
);

CREATE INDEX IF NOT EXISTS click_events_occurred_idx
  ON click_events(occurred_at DESC);

CREATE INDEX IF NOT EXISTS click_events_tenant_idx
  ON click_events(tenant_id, occurred_at DESC);

-- "What is clicked on this page", the query the dashboard will want.
CREATE INDEX IF NOT EXISTS click_events_page_idx
  ON click_events(host, path, occurred_at DESC);
