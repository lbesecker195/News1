import { aiJSON } from "./openai.service.mjs";
import { CATEGORIES } from "./editorial.service.mjs";

/*
 * Which parts of the news actually bear on one person's working life.
 *
 * A job title and an employer say a great deal about what matters: a
 * compliance officer at a bank and a studio's head of production read the same
 * day's news for completely different reasons, and most of it matters to
 * neither. This ranks the archive's sections for one reader and says why, so
 * the report can show its reasoning rather than asserting relevance.
 *
 * Falls back to a defensible default rather than failing: a report with
 * ordinary sections beats no report.
 */

export const DEFAULT_SECTIONS = ["Business", "Technology", "World"];

export async function sectionsFor({
  title,
  company,
  industry,
  limit = 4
} = {}) {
  /* Nothing known about the reader is nothing to reason from. */
  if (!title && !company && !industry) {
    return {
      sections: DEFAULT_SECTIONS.slice(0, limit).map(name => ({
        name,
        why: "A general selection — we know nothing about this reader yet."
      })),
      personalised: false
    };
  }

  const instruction = [
    "You decide which parts of the news bear on one person's working life.",
    "",
    `Choose ${limit} sections from this list, most consequential first:`,
    CATEGORIES.join(", "),
    "",
    "Judge by what would change how this person does their job, what their",
    "employer is exposed to, and what their market reacts to. A section is not",
    "relevant merely because it is important in general.",
    "",
    "For each, give one sentence — under 25 words — saying why it bears on",
    "this particular person. Address the reason to their role, not to the",
    "section: 'ransomware disclosure rules decide what your team must report',",
    "not 'compliance news is important'.",
    "",
    'Return {"sections":[{"name":"...","why":"..."}]} using only names from',
    "the list above."
  ].join("\n");

  try {
    const output = await aiJSON(instruction, {
      title: title ?? null,
      company: company ?? null,
      industry: industry ?? null
    }, { maxRetries: 1 });

    const chosen = (Array.isArray(output?.sections) ? output.sections : [])
      /* The model may only pick from sections that exist. */
      .map(entry => ({
        name: CATEGORIES.find(
          category => category.toLowerCase() === String(entry?.name).toLowerCase()
        ),
        why: String(entry?.why ?? "").trim().slice(0, 200)
      }))
      .filter(entry => entry.name)
      .slice(0, limit);

    /* De-duplicate: a repeated section would fill the report with one topic. */
    const seen = new Set();
    const sections = chosen.filter(entry => {
      if (seen.has(entry.name)) return false;

      seen.add(entry.name);
      return true;
    });

    if (!sections.length) throw new Error("no usable sections returned");

    return { sections, personalised: true };
  } catch (error) {
    console.warn(`Section ranking failed, using defaults: ${error.message}`);

    return {
      sections: DEFAULT_SECTIONS.slice(0, limit).map(name => ({
        name,
        why: "A general selection — this reader's sections could not be ranked."
      })),
      personalised: false
    };
  }
}
