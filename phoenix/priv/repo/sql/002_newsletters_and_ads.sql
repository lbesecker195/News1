-- Personalised newsletters and the advertising that pays for them.
--
-- Three things arrive here:
--   1. Stories we rewrite ourselves, deduplicated across the whole platform so
--      the same article is never worked twice.
--   2. A per-contact record of which story was featured for whom.
--   3. An ad server: advertisers, campaigns, creatives, and the delivery
--      records that make impressions and clicks billable.
--
-- Idempotent. scripts/migrate.mjs wraps this in a transaction.

-- ---------------------------------------------------------------------------
-- Enrichment. Everything else a contact needs is already on the table; the
-- industry is what campaign targeting and story selection both read.
-- ---------------------------------------------------------------------------
ALTER TABLE contacts ADD COLUMN IF NOT EXISTS industry text;
ALTER TABLE contacts ADD COLUMN IF NOT EXISTS enriched_at timestamptz;

CREATE INDEX IF NOT EXISTS contacts_industry_idx ON contacts (industry);

-- ---------------------------------------------------------------------------
-- Recipients are added on the customer's authority rather than by confirming
-- an invitation, so the attestation itself is the record: who claimed the right
-- to mail this person, and when. If a complaint ever has to be answered, this
-- is the evidence.
-- ---------------------------------------------------------------------------
ALTER TABLE subscribers ADD COLUMN IF NOT EXISTS authorised_at timestamptz;
ALTER TABLE subscribers ADD COLUMN IF NOT EXISTS authorised_by citext;

-- ---------------------------------------------------------------------------
-- Stories.
--
-- Three a day per topic, rewritten in our own words from the headline and
-- publisher metadata. `fingerprint` is the platform-wide guard against
-- rehashing: once an article has been written up it is never picked again, for
-- any topic or any customer.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stories (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topic_key    text        NOT NULL REFERENCES topics(key) ON DELETE CASCADE,
  issue_date   date        NOT NULL,

  -- What we were given.
  source_url   text        NOT NULL,
  source_name  text        NOT NULL,
  source_title text        NOT NULL,
  published_at timestamptz,

  -- What we wrote.
  headline     text        NOT NULL,
  standfirst   text        NOT NULL,
  body         text        NOT NULL,

  -- Normalised source URL, hashed. Unique across the platform.
  fingerprint  text        NOT NULL UNIQUE,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS stories_topic_issue_idx
  ON stories (topic_key, issue_date DESC);

-- ---------------------------------------------------------------------------
-- Per-contact selection. Which of the day's three leads that reader's issue,
-- and in what order the rest follow. Cached so a delivery retry does not pay
-- for the model twice, and so a send can be reproduced exactly.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS newsletter_picks (
  contact_id   uuid        NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  topic_key    text        NOT NULL REFERENCES topics(key) ON DELETE CASCADE,
  issue_date   date        NOT NULL,
  story_ids    uuid[]      NOT NULL,
  reason       text,
  personalised boolean     NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (contact_id, topic_key, issue_date)
);

-- ---------------------------------------------------------------------------
-- Advertisers and campaigns.
--
-- Targeting is a jsonb document rather than columns so a new dimension does not
-- need a migration: {"titles":["%vp%"],"industries":["SaaS"],"topics":["ai"]}.
-- An empty or absent key means "no restriction on this dimension".
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS advertisers (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text        NOT NULL,
  contact_email citext,
  active        boolean     NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS campaigns (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  advertiser_id     uuid        NOT NULL REFERENCES advertisers(id) ON DELETE CASCADE,
  name              text        NOT NULL,
  status            text        NOT NULL DEFAULT 'draft',
  starts_on         date        NOT NULL,
  ends_on           date        NOT NULL,

  -- 0 means uncapped.
  daily_cap         int         NOT NULL DEFAULT 0,
  total_cap         int         NOT NULL DEFAULT 0,

  -- Cents per thousand impressions. Reporting only; nothing here bills a card.
  cpm_cents         int         NOT NULL DEFAULT 0,

  targeting         jsonb       NOT NULL DEFAULT '{}'::jsonb,

  -- Denormalised counters. The ad_events table is the ledger; these make the
  -- cap check a single indexed read instead of an aggregate over millions.
  impressions       bigint      NOT NULL DEFAULT 0,
  clicks            bigint      NOT NULL DEFAULT 0,

  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT campaigns_status_check
    CHECK (status IN ('draft', 'active', 'paused', 'completed')),
  CONSTRAINT campaigns_dates_check CHECK (ends_on >= starts_on)
);

CREATE INDEX IF NOT EXISTS campaigns_servable_idx
  ON campaigns (starts_on, ends_on)
  WHERE status = 'active';

CREATE TABLE IF NOT EXISTS creatives (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid        NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,

  -- 'sponsored_story' is the labelled article slot; 'banner' is the smaller
  -- unit placed between stories.
  slot        text        NOT NULL,
  headline    text        NOT NULL,
  body        text        NOT NULL,
  cta         text,
  image_url   text,
  click_url   text        NOT NULL,
  active      boolean     NOT NULL DEFAULT true,
  weight      int         NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT creatives_slot_check CHECK (slot IN ('sponsored_story', 'banner'))
);

CREATE INDEX IF NOT EXISTS creatives_campaign_idx
  ON creatives (campaign_id, slot)
  WHERE active;

-- ---------------------------------------------------------------------------
-- Delivery records. One row per creative per recipient per issue, created when
-- the newsletter is built. The row id is the opaque token in the tracking pixel
-- and the click URL, so neither can be enumerated or forged into someone
-- else's attribution.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ad_placements (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid        NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  creative_id uuid        NOT NULL REFERENCES creatives(id) ON DELETE CASCADE,
  contact_id  uuid        REFERENCES contacts(id) ON DELETE SET NULL,
  tenant_id   uuid        REFERENCES tenants(id) ON DELETE SET NULL,
  issue_date  date        NOT NULL,
  slot        text        NOT NULL,
  served_at   timestamptz NOT NULL DEFAULT now(),
  first_seen  timestamptz,
  first_click timestamptz
);

CREATE INDEX IF NOT EXISTS ad_placements_campaign_day_idx
  ON ad_placements (campaign_id, issue_date);

-- ---------------------------------------------------------------------------
-- The event ledger. Every impression and click, including repeats, so delivery
-- can be audited independently of the counters on `campaigns`.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ad_events (
  id           bigserial PRIMARY KEY,
  placement_id uuid        NOT NULL REFERENCES ad_placements(id) ON DELETE CASCADE,
  campaign_id  uuid        NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  kind         text        NOT NULL,
  occurred_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ad_events_kind_check CHECK (kind IN ('impression', 'click'))
);

CREATE INDEX IF NOT EXISTS ad_events_campaign_idx
  ON ad_events (campaign_id, occurred_at);
