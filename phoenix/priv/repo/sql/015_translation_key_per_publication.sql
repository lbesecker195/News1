-- A translation group belongs to a publication, like the slug it is derived
-- from.
--
-- 013 made a slug unique per publication so two sites could each run a
-- "spring-collections-2027", but left this index global. Since
-- Stories.create_editorial/1 sets translation_key to the slug, the second site
-- to use that slug would violate this index instead — and the insert's
-- ON CONFLICT names the slug index, so it would raise rather than be ignored,
-- failing the whole article. Only editorial and import rows carry a
-- translation_key, and both belong to exactly one publication, so scoping it
-- loses nothing.

DROP INDEX IF EXISTS stories_translation_language_key;

CREATE UNIQUE INDEX IF NOT EXISTS stories_publication_translation_key
  ON stories (publication_id, translation_key, language)
  WHERE translation_key IS NOT NULL;
