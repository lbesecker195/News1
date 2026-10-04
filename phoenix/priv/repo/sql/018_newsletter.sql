-- The newsletter: who asked for which publication's daily edition, and which
-- editions have gone out.
--
-- A subscription belongs to one publication and one contact. The reader types
-- an address on that publication's own site and is subscribed from that
-- moment: every address entered is taken as opted in, so there is no pending
-- state and no confirmation token. Unsubscribing goes through contacts, like
-- every other RNews1 email, so one opt-out is honoured across the whole
-- platform rather than one publication at a time.

CREATE TABLE IF NOT EXISTS newsletter_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  publication_id uuid NOT NULL REFERENCES publications(id) ON DELETE CASCADE,
  contact_id uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT newsletter_subscriptions_pub_contact_key UNIQUE (publication_id, contact_id)
);

-- One row per publication per day it was sent. The scheduler claims a row
-- before enqueueing, so a restart, a second node or a slow tick can never mail
-- the same edition twice; the outbox dedupe key backs that up per recipient.
CREATE TABLE IF NOT EXISTS edition_runs (
  publication_id uuid NOT NULL REFERENCES publications(id) ON DELETE CASCADE,
  edition_date date NOT NULL,
  recipients integer NOT NULL DEFAULT 0,
  scheduled_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (publication_id, edition_date)
);

ALTER TABLE outbox DROP CONSTRAINT IF EXISTS outbox_kind_check;

ALTER TABLE outbox ADD CONSTRAINT outbox_kind_check
  CHECK (kind IN ('login', 'confirmation', 'digest', 'campaign', 'edition'));
