-- Plans.
--
--   standard    $25/month. A branded subdomain on the platform domain, one
--               industry and two keywords, the feed and the embed.
--   enterprise  Hosted on a hostname the customer owns, with our branding off
--               the embed. The archive at www is the platform's own enterprise
--               account: the demo is the product, not a mock-up of it.
--
-- Comping is orthogonal and already here: comped_reason set with
-- billing_status 'active' is an account entitled to the service with no
-- PayPal subscription behind it.

ALTER TABLE tenants
  ADD COLUMN IF NOT EXISTS plan text NOT NULL DEFAULT 'standard';

DO $$
BEGIN
  ALTER TABLE tenants
    ADD CONSTRAINT tenants_plan_check CHECK (plan IN ('standard', 'enterprise'));
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
