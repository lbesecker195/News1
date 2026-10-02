-- Who owns a publication.
--
-- Publications arrived as ours alone, so there was nothing to own them. An
-- account that holds several news sites needs the link, and the dashboard needs
-- it to list anything at all: without it the site switcher can only ever show
-- the one briefing fused to the tenants row.
--
-- Nullable, and NULL must stay legal forever: Publications.ensure_default/0
-- runs at boot BEFORE the house account exists, and when ARCHIVE_TENANT_EMAIL
-- is unset the house account never exists at all. NULL means "the platform's".
--
-- RESTRICT rather than CASCADE: stories.publication_id already pins a
-- publication that has published anything, so deleting the owning tenant must
-- fail loudly here rather than half-succeed and strand the stories.

ALTER TABLE publications
  ADD COLUMN IF NOT EXISTS tenant_id uuid REFERENCES tenants(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS publications_tenant_idx ON publications(tenant_id);
