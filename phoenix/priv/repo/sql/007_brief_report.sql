-- The daily report page.
--
-- A brief stored only its rendered email HTML, which is the right shape for a
-- mail client and the wrong one for a page someone reads on screen or prints
-- to PDF. Keeping the story ids lets the report be rendered from data, so the
-- same issue can be laid out three ways — email, web, print — without any of
-- them being a reformat of another.
--
-- Idempotent. scripts/migrate.mjs wraps this in a transaction.

ALTER TABLE briefs ADD COLUMN IF NOT EXISTS story_ids uuid[] NOT NULL DEFAULT '{}';
ALTER TABLE briefs ADD COLUMN IF NOT EXISTS issue_date date;

-- Backfill so existing rows still have a date to print.
UPDATE briefs SET issue_date = created_at::date WHERE issue_date IS NULL;

CREATE INDEX IF NOT EXISTS briefs_tenant_issue_idx
  ON briefs (tenant_id, issue_date DESC);
