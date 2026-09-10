import { z } from "zod";

import { isLoginToken, isUUID } from "./ids.mjs";

export { isLoginToken, isUUID };

export const emailSchema = z.string()
  .trim()
  .max(254)
  .toLowerCase()
  .refine(
    value => /^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/.test(value),
    "Enter a valid email address."
  );

/*
 * One industry and exactly two keywords. The narrow shape is deliberate: three
 * terms is what produces a focused enough Google News query to yield three
 * stories a day worth rewriting, and a broad query returns noise.
 */
export const KEYWORD_COUNT = 2;

export const companySchema = z.object({
  name: z.string().trim().min(1).max(100),
  domain: z.string().trim().min(1).max(253),
  industry: z.string().trim().min(1).max(100),
  keywords: z.array(
    z.string().trim().min(1).max(60)
  ).length(KEYWORD_COUNT, `Choose exactly ${KEYWORD_COUNT} keywords.`),
  language: z.enum(["en", "es", "fr", "de"])
});

export const suggestionInputSchema = z.object({
  name: z.string().trim().max(100),
  domain: z.string().trim().max(253),
  industry: z.string().trim().max(100)
});

export const suggestionResultSchema = z.object({
  industry: z.string().trim().min(1).max(100),
  keywords: z.array(
    z.string().trim().min(1).max(60)
  ).min(KEYWORD_COUNT).max(6)
    /* The model is asked for a few; the form only takes two. */
    .transform(list => list.slice(0, KEYWORD_COUNT))
});

/*
 * The dashboard checkbox is the customer's attestation that they are entitled
 * to mail this person. It is required, so a missing or false value is a
 * validation failure rather than a silently unattested recipient.
 */
export const recipientSchema = z.object({
  email: emailSchema,
  authorised: z.literal(true)
});

export const contactImportSchema = z.object({
  email: emailSchema,
  name: z.string().trim().max(120).optional(),
  company: z.string().trim().max(120).optional(),
  title: z.string().trim().max(120).optional(),
  source: z.string().trim().max(80).optional()
});
