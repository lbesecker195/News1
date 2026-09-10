import * as companies from "../models/company.model.mjs";
import * as subscribersModel from "../models/subscriber.model.mjs";

import {
  APP,
  aiJSON,
  hash,
  companyDomain
} from "../services/platform.service.mjs";

import {
  companySchema,
  suggestionInputSchema,
  suggestionResultSchema
} from "../utils/validation.mjs";

import { HttpError } from "../utils/http-error.mjs";
import { isBillingActive } from "../utils/billing-status.mjs";

export const FEED_ITEMS = 8;

/* Publishing needs both a live subscription and a complete roster. */
function stakeholders(count, billingStatus) {
  return {
    count,
    required: subscribersModel.REQUIRED_STAKEHOLDERS,
    remaining: Math.max(0, subscribersModel.REQUIRED_STAKEHOLDERS - count),
    published: count >= subscribersModel.REQUIRED_STAKEHOLDERS &&
      isBillingActive(billingStatus)
  };
}

export async function me(req, res) {
  const tenant = req.tenant;
  const count = await subscribersModel.countForTenant(tenant.id);

  res.set("Cache-Control", "no-store").json({
    tenant: {
      name: tenant.name,
      domain: tenant.domain,
      industry: tenant.industry,
      keywords: tenant.keywords,
      language: tenant.language,
      billing_status: tenant.billing_status
    },
    subscribers: await subscribersModel.listForTenant(tenant.id),
    stakeholders: stakeholders(count, tenant.billing_status),
    rss: `${APP}/feed/${tenant.public_token}.xml`,
    embed: `${APP}/embed/${tenant.public_token}`
  });
}

export async function save(req, res) {
  const input = companySchema.parse(req.body);

  try {
    input.domain = companyDomain(input.domain);
  } catch {
    throw new HttpError(400, "Enter a valid company domain.");
  }

  /*
   * The topic key is a hash of the normalised query, so two tenants who choose
   * the same terms in the same language share one crawl. Quotes are stripped
   * rather than escaped because the Google News query syntax has no escape.
   */
  const terms = [
    ...new Set(
      [input.industry, ...input.keywords]
        .map(value => value.replace(/["\\]/g, "").trim())
        .filter(Boolean)
    )
  ];

  if (!terms.length) {
    throw new HttpError(400, "Add an industry or at least one keyword.");
  }

  const query = terms.map(value => `"${value}"`).join(" OR ");

  const topic = {
    query,
    key: hash(`${input.language}:${query}`)
  };

  await companies.saveSettings(req.tenant.id, input, topic);

  res.json({
    message: "Saved. The worker will prepare your preview shortly."
  });
}

export async function suggest(req, res) {
  const input = suggestionInputSchema.parse(req.body);

  const output = await aiJSON(
    `Suggest a news industry label and exactly 2 industry keywords.
Do not claim you visited the website.
Domain and company name may be ambiguous.
These are suggestions for the user to confirm.
Return {"industry":"...","keywords":["..."]}.`,
    input
  );

  const suggestion = suggestionResultSchema.safeParse(output);

  /*
   * A malformed model response is an upstream failure, not bad user input, so
   * it must not come back as a 400 blaming the form.
   */
  if (!suggestion.success) {
    throw new HttpError(
      502,
      "Suggestions are unavailable right now. Enter your topics manually."
    );
  }

  res.json(suggestion.data);
}

export async function preview(req, res) {
  const data = await companies.findPreview(req.tenant.topic_key);

  res.set("Cache-Control", "no-store").json({
    ...data,
    items: data.items.slice(0, FEED_ITEMS)
  });
}
