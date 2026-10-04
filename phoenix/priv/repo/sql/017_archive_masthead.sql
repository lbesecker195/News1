-- The archive's newsletter masthead reads its publication row, as every other
-- publication's does — the same template for all of them. The row was seeded as
-- 'Rnews1' with no tagline. The brand is 'RNews1' and its line is the brand line.
--
-- Guarded on the seeded values so a deliberate rename since is left alone. The
-- archive's own website is unaffected: it takes its masthead from content.json.

UPDATE publications SET name = 'RNews1' WHERE slug = 'archive' AND name = 'Rnews1';

UPDATE publications SET tagline = 'Real News, made for One.' WHERE slug = 'archive' AND tagline IS NULL;
