-- Editorial articles, imported from the Hugo site, in twelve languages.
--
-- These share a table with crawled stories because they are the same kind of
-- thing — a headline, a standfirst, a body, a category — and the public
-- surfaces should not care which pipeline produced a page. What separates them
-- is `origin`, and the fields each one leaves null.
--
-- Locales stay separate rows, deliberately. A translation is its own page with
-- its own URL and its own slug; `translation_key` links the set so each can
-- point at its siblings with hreflang, which is what stops search engines
-- treating twelve languages as duplicate content.
--
-- Idempotent. scripts/migrate.mjs wraps this in a transaction.

ALTER TABLE stories ADD COLUMN IF NOT EXISTS language text NOT NULL DEFAULT 'en';
ALTER TABLE stories ADD COLUMN IF NOT EXISTS translation_key text;
ALTER TABLE stories ADD COLUMN IF NOT EXISTS slug text;
ALTER TABLE stories ADD COLUMN IF NOT EXISTS category text;
ALTER TABLE stories ADD COLUMN IF NOT EXISTS tags text[] NOT NULL DEFAULT '{}';

-- 'crawl' — written by the daily pipeline from a publisher's article.
-- 'import' — editorial brought over from the Hugo site.
ALTER TABLE stories ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'crawl';

-- Imported editorial has no crawl provenance: no topic, no source URL, no
-- fingerprint. Those columns describe how a story was found, and these were
-- not found, they were written.
ALTER TABLE stories ALTER COLUMN topic_key DROP NOT NULL;
ALTER TABLE stories ALTER COLUMN source_url DROP NOT NULL;
ALTER TABLE stories ALTER COLUMN source_name DROP NOT NULL;
ALTER TABLE stories ALTER COLUMN source_title DROP NOT NULL;
ALTER TABLE stories ALTER COLUMN fingerprint DROP NOT NULL;

-- One article per language per translation group. This is what makes a
-- re-import an update rather than a duplicate.
CREATE UNIQUE INDEX IF NOT EXISTS stories_translation_language_key
  ON stories (translation_key, language)
  WHERE translation_key IS NOT NULL;

-- The public URL is /{language}/{category}/{slug}, preserved from the Hugo
-- site so existing links and any accumulated ranking survive the move.
CREATE UNIQUE INDEX IF NOT EXISTS stories_language_slug_key
  ON stories (language, slug)
  WHERE slug IS NOT NULL;

CREATE INDEX IF NOT EXISTS stories_origin_published_idx
  ON stories (origin, published_at DESC);

CREATE INDEX IF NOT EXISTS stories_category_idx
  ON stories (language, category)
  WHERE origin = 'import';
