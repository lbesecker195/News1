-- A publication's own line, shown beside its name and used as the meta
-- description. Null renders nothing at all, which is the right default: a new
-- news site should show its own name and its own stories, never the archive's
-- product copy about briefings written for one reader.
--
-- The default publication does not use this. It keeps reading content.json
-- through Content.brand(), so www.rnews1.com renders exactly as it did.

ALTER TABLE publications ADD COLUMN IF NOT EXISTS tagline text;
