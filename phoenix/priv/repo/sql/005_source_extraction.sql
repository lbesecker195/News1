-- Provenance for stories written from the article rather than the headline.
--
-- What is recorded is how we got the text and how much there was — never the
-- publisher's text itself. The body is used to write from and then dropped, so
-- there is no copy of anyone's reporting in this database, only a record of
-- having read it.
--
-- Idempotent. scripts/migrate.mjs wraps this in a transaction.

-- The publisher URL the Google News redirect actually resolved to.
ALTER TABLE stories ADD COLUMN IF NOT EXISTS resolved_url text;

-- jsonld | articletag | paragraphs | robots_denied | no_content | headline_only
ALTER TABLE stories ADD COLUMN IF NOT EXISTS extraction text
  NOT NULL DEFAULT 'headline_only';

-- Characters of source read. Zero means the story was written from the
-- headline alone, which is still a supported outcome.
ALTER TABLE stories ADD COLUMN IF NOT EXISTS source_chars int NOT NULL DEFAULT 0;

-- Longest run of consecutive words our text shares with the source. The
-- rewrite is rejected above a threshold, so this should stay low; it is kept
-- because "we measured it, every time, and here are the numbers" is a far
-- better answer to a publisher than "we intended not to".
ALTER TABLE stories ADD COLUMN IF NOT EXISTS verbatim_run int NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS stories_verbatim_run_idx
  ON stories (verbatim_run DESC);
