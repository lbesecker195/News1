-- Customer sites.
--
-- Every tenant gets a brandable subdomain under SITES_DOMAIN
-- (acme.rnews1.com) and may point a hostname they own at it with a CNAME
-- (news.acme.com → acme.rnews1.com). The public feed, embed and hosted
-- articles are served on those hosts; the token URLs on the app host remain
-- as legacy entry points.

ALTER TABLE tenants
  ADD COLUMN IF NOT EXISTS subdomain            text,
  ADD COLUMN IF NOT EXISTS subdomain_changed_at timestamptz;

-- Existing tenants: a label from the company name, else from the owner's
-- email domain, else a neutral placeholder the app will replace with the
-- company name the first time settings are saved. Mirrors utils/hosts.mjs.
DO $$
DECLARE
  t         record;
  base      text;
  candidate text;
  n         int;
  reserved  text[] := ARRAY[
    'www','app','admin','api','mail','mg','email','smtp','imap','pop','ftp',
    'ns1','ns2','cdn','static','assets','status','help','support','docs',
    'blog','dev','staging','test','login','register','billing','paypal',
    'webhooks','feed','feeds','embed','news','brief','pdf','rnews1','localhost',
    'gmail','googlemail','yahoo','outlook','hotmail','live','icloud','me',
    'aol','proton','protonmail','pm','gmx','yandex','zoho'
  ];
BEGIN
  FOR t IN
    SELECT id, name, owner_email FROM tenants
    WHERE subdomain IS NULL ORDER BY created_at
  LOOP
    base := trim(both '-' from
      regexp_replace(lower(coalesce(t.name, '')), '[^a-z0-9]+', '-', 'g'));

    IF length(base) < 3 THEN
      base := split_part(split_part(t.owner_email::text, '@', 2), '.', 1);
      base := trim(both '-' from
        regexp_replace(lower(base), '[^a-z0-9]+', '-', 'g'));
    END IF;

    IF length(base) < 3 OR base = ANY(reserved) THEN
      base := 'news-' || left(replace(t.id::text, '-', ''), 8);
    END IF;

    base := trim(both '-' from left(base, 40));
    candidate := base;
    n := 1;

    WHILE EXISTS (SELECT 1 FROM tenants WHERE subdomain = candidate) LOOP
      n := n + 1;
      candidate := base || '-' || n;
    END LOOP;

    UPDATE tenants SET subdomain = candidate WHERE id = t.id;
  END LOOP;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS tenants_subdomain_key ON tenants(subdomain);
ALTER TABLE tenants ALTER COLUMN subdomain SET NOT NULL;

-- A released subdomain keeps redirecting to the tenant's current address for
-- a while, and cannot be taken by anyone else in that time. Without this a
-- rename would strand every link already shared and let a stranger squat the
-- old brand the next minute.
CREATE TABLE IF NOT EXISTS subdomain_history (
  subdomain   text        PRIMARY KEY,
  tenant_id   uuid        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  released_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS subdomain_history_tenant_idx
  ON subdomain_history(tenant_id);

-- One custom hostname per tenant. A claim is only served once verified —
-- either the hostname's CNAME points at the tenant's own platform subdomain,
-- or a TXT record carries the verification token.
CREATE TABLE IF NOT EXISTS tenant_domains (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid        NOT NULL UNIQUE REFERENCES tenants(id) ON DELETE CASCADE,
  hostname           text        NOT NULL UNIQUE,
  verification_token text        NOT NULL,
  verified_at        timestamptz,
  last_checked_at    timestamptz,
  last_error         text,
  -- Set on the first failed re-check after verification; cleared on success.
  -- The domain is un-verified only after failing for days, not one blip.
  failing_since      timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now()
);
