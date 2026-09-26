-- Publications: the editorial sites we run.
--
-- The archive at ARCHIVE_ORIGIN was the only one, and all three of the things
-- that define it were constants: one hostname, one list of twelve sections, one
-- list of twelve languages. Every editorial story belonged to it implicitly,
-- because there was nothing else it could belong to. A second news site on its
-- own domain makes all three per-site, so they become rows.
--
-- The default publication is seeded here with a hostname that cannot resolve
-- (.invalid is reserved by RFC 2606) because the archive's real hostname is an
-- environment value and differs between dev and production. The application
-- reconciles hostname, languages and sections against the environment on boot.
-- Seeding it here rather than there means the backfill below can run in the
-- same transaction as the column that needs it.

CREATE TABLE IF NOT EXISTS publications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  name text NOT NULL,
  hostname text NOT NULL UNIQUE,
  languages text[] NOT NULL DEFAULT ARRAY['en'],
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- One standing beat. The name is the {topic} segment of the article URL, so it
-- joins the URL contract the moment it publishes anything; the query is what
-- the discovery pass searches for.
CREATE TABLE IF NOT EXISTS publication_sections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  publication_id uuid NOT NULL REFERENCES publications(id) ON DELETE CASCADE,
  name text NOT NULL,
  query text NOT NULL,
  position integer NOT NULL DEFAULT 0,
  UNIQUE (publication_id, name)
);

CREATE INDEX IF NOT EXISTS publication_sections_order_idx
  ON publication_sections(publication_id, position);

INSERT INTO publications(slug, name, hostname, languages)
VALUES ('archive', 'Rnews1', 'archive.invalid', ARRAY['ar','bn','en','es','fr','hi','it','la','pt','ru','ur','zh'])
ON CONFLICT (slug) DO NOTHING;

-- The archive's twelve sections, which were a module attribute in Editorial.
-- Seeded here rather than reconciled at boot: they are the {topic} segment of
-- every URL the site has ever published, so they are schema, not configuration,
-- and a half-finished boot must never be able to leave only some of them.
INSERT INTO publication_sections(publication_id, name, query, position)
SELECT p.id, s.name, s.query, s.position
FROM publications p,
  (VALUES
    ('AI',            'artificial intelligence machine learning research industry', 0),
    ('Business',      'business economy markets corporate earnings',                1),
    ('Compliance',    'regulatory compliance data breach security enforcement',     2),
    ('Cosmos',        'astronomy space telescope cosmology mission',                3),
    ('Crypto',        'cryptocurrency bitcoin blockchain digital assets',           4),
    ('Entertainment', 'entertainment film television music industry',               5),
    ('Health',        'health medicine clinical research public health',            6),
    ('Science',       'scientific research discovery study published',              7),
    ('Sports',        'sports competition league championship',                     8),
    ('Technology',    'technology software hardware engineering industry',          9),
    ('USA',           'United States national news policy',                        10),
    ('World',         'world international affairs diplomacy',                     11)
  ) AS s(name, query, position)
WHERE p.slug = 'archive'
ON CONFLICT (publication_id, name) DO NOTHING;

-- Editorial and imported stories belong to exactly one publication.
ALTER TABLE stories ADD COLUMN IF NOT EXISTS publication_id uuid REFERENCES publications(id);

UPDATE stories
SET publication_id = (SELECT id FROM publications WHERE slug = 'archive')
WHERE publication_id IS NULL AND origin IN ('import', 'editorial');

CREATE INDEX IF NOT EXISTS stories_publication_idx
  ON stories(publication_id, language, category)
  WHERE origin IN ('import', 'editorial');

-- A slug is unique per publication, not globally: two sites may each run a
-- "spring-collections-2027" and neither should push the other into a suffix.
-- Both editorial inserts infer their ON CONFLICT target from this index, so
-- they name the same three columns and the same predicate.
DROP INDEX IF EXISTS stories_language_slug_key;

CREATE UNIQUE INDEX IF NOT EXISTS stories_publication_slug_key
  ON stories (publication_id, language, slug)
  WHERE slug IS NOT NULL;
