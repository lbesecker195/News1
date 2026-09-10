import * as ads from "../models/ad.model.mjs";
import { APP } from "./platform.service.mjs";

/*
 * Fills one reader's issue with advertising.
 *
 * Every slot is filled independently and no campaign takes two slots in the
 * same issue, so a reader never sees the same advertiser twice in one send.
 */

export const BANNER_SLOTS = 2;

export async function selectAds(db, {
  contact,
  tenantId,
  issueDate,
  topicTerms
}) {
  const claimed = new Set();

  const sponsored = await fill(db, {
    slot: "sponsored_story",
    count: 1,
    claimed,
    contact,
    tenantId,
    issueDate,
    topicTerms
  });

  const banners = await fill(db, {
    slot: "banner",
    count: BANNER_SLOTS,
    claimed,
    contact,
    tenantId,
    issueDate,
    topicTerms
  });

  return { sponsored: sponsored[0] ?? null, banners };
}

async function fill(db, {
  slot,
  count,
  claimed,
  contact,
  tenantId,
  issueDate,
  topicTerms
}) {
  const candidates = await ads.eligibleCreatives({
    slot,
    issueDate,
    title: contact?.title ?? null,
    industry: contact?.industry ?? null,
    topicTerms
  });

  const chosen = [];

  for (const candidate of candidates) {
    if (chosen.length >= count) break;
    if (claimed.has(candidate.campaign_id)) continue;

    claimed.add(candidate.campaign_id);

    const placementId = await ads.recordPlacement(db, {
      campaignId: candidate.campaign_id,
      creativeId: candidate.creative_id,
      contactId: contact?.id ?? null,
      tenantId,
      issueDate,
      slot
    });

    chosen.push({
      headline: candidate.headline,
      body: candidate.body,
      cta: candidate.cta,
      imageUrl: candidate.image_url,
      /* Never the advertiser's URL directly: the click has to be counted. */
      clickUrl: `${APP}/a/c/${placementId}`,
      pixelUrl: `${APP}/a/p/${placementId}.gif`
    });
  }

  return chosen;
}
