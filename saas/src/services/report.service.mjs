import { transaction } from "../config/database.mjs";

import * as briefs from "../models/brief.model.mjs";
import * as stories from "../models/story.model.mjs";

import { sectionsFor } from "./impact.service.mjs";

/*
 * A report built for one reader.
 *
 * Which sections bear on them is decided from their job and employer, then
 * filled from the archive. The reasoning is stored with the report so the page
 * can show why these sections and not others — a report that asserts relevance
 * is less persuasive than one that explains it.
 *
 * It becomes an ordinary brief row, so it is served, printed and converted to
 * PDF by everything that already handles briefs.
 */
export async function buildCustomReport({
  contact,
  language = "en",
  sectionCount = 4,
  perSection = 2,
  tenantId = null
}) {
  const ranked = await sectionsFor({
    title: contact.title,
    company: contact.company,
    industry: contact.industry,
    limit: sectionCount
  });

  const selected = await stories.recentBySection({
    language,
    sections: ranked.sections.map(section => section.name),
    perSection
  });

  const meta = {
    reader: {
      name: contact.name ?? null,
      title: contact.title ?? null,
      company: contact.company ?? null,
      industry: contact.industry ?? null
    },
    sections: ranked.sections,
    personalised: ranked.personalised,
    language
  };

  const issueDate = new Date().toISOString().slice(0, 10);

  const id = await transaction(db => briefs.create(db, {
    tenantId,
    contactId: contact.id ?? null,
    /*
     * No emailed version: this report was never sent, so there is nothing to
     * keep a record of. The page renders from the stories and the meta.
     */
    html: "",
    storyIds: selected.map(story => story.id),
    issueDate,
    meta
  }));

  return {
    id,
    sections: ranked.sections,
    personalised: ranked.personalised,
    stories: selected.length,
    issueDate
  };
}
