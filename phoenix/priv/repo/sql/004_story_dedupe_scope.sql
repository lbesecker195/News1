-- Scope story de-duplication to the topic rather than the platform.
--
-- The original constraint was global: once any customer's topic had an article
-- written up, no other topic could ever cover it. That is wrong. Two customers
-- following the same beat should both get the story — they are different
-- audiences, and each gets its own rewrite.
--
-- What must not happen is the same article being written up twice for the same
-- topic, which is what would make a reader see the same story again next week.
--
-- Idempotent. scripts/migrate.mjs wraps this in a transaction.

ALTER TABLE stories DROP CONSTRAINT IF EXISTS stories_fingerprint_key;

CREATE UNIQUE INDEX IF NOT EXISTS stories_topic_fingerprint_key
  ON stories (topic_key, fingerprint);

-- Still worth an index on its own for "has anyone covered this?" questions.
CREATE INDEX IF NOT EXISTS stories_fingerprint_idx ON stories (fingerprint);
