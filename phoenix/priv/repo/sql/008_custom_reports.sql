-- Reports built for one person rather than one company.
--
-- A daily brief belongs to a tenant and covers their topics. A custom report
-- belongs to a reader: which sections of the archive actually bear on someone
-- with their job, at their employer, and the stories from those sections.
--
-- It reuses the briefs table because it is the same object — a fixed set of
-- stories, at an unguessable URL, that renders and prints as a report. What it
-- adds is who it was built for and why those sections were chosen.
--
-- Idempotent. scripts/migrate.mjs wraps this in a transaction.

ALTER TABLE briefs ADD COLUMN IF NOT EXISTS contact_id uuid
  REFERENCES contacts(id) ON DELETE SET NULL;

-- { reader: {name,title,company}, sections: [{name, why}] }
ALTER TABLE briefs ADD COLUMN IF NOT EXISTS meta jsonb NOT NULL DEFAULT '{}'::jsonb;

-- A tenant may hold no company topic and still commission reports for people.
ALTER TABLE briefs ALTER COLUMN tenant_id DROP NOT NULL;

CREATE INDEX IF NOT EXISTS briefs_contact_idx ON briefs (contact_id);
