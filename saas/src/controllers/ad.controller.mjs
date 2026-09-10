import * as ads from "../models/ad.model.mjs";

import { HttpError } from "../utils/http-error.mjs";
import { isUUID } from "../utils/validation.mjs";
import { safeURL } from "../utils/html.mjs";

/*
 * A 1x1 transparent GIF, inline so tracking never depends on a file on disk.
 */
const PIXEL = Buffer.from(
  "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7",
  "base64"
);

/*
 * The pixel always returns an image, even for an unknown or malformed token.
 * A broken image icon in a customer's newsletter is a worse outcome than a
 * missing row in our own analytics.
 */
export async function pixel(req, res) {
  const id = String(req.params.id).replace(/\.gif$/i, "");

  if (isUUID(id)) {
    await ads.recordImpression(id).catch(error => {
      console.error("Impression not recorded:", error.message);
    });
  }

  res.set({
    "Content-Type": "image/gif",
    "Content-Length": String(PIXEL.length),
    /* Every open must reach us, so this must never be cached. */
    "Cache-Control": "no-store, no-cache, must-revalidate, private",
    Pragma: "no-cache"
  }).end(PIXEL);
}

export async function click(req, res) {
  if (!isUUID(req.params.id)) {
    throw new HttpError(404, "This link is no longer available.");
  }

  const destination = await ads.recordClick(req.params.id);

  if (!destination) {
    throw new HttpError(404, "This link is no longer available.");
  }

  /*
   * safeURL is the guard against an advertiser storing a javascript: or data:
   * click_url and turning our domain into the delivery vehicle for it.
   */
  const target = safeURL(destination);

  if (target === "#") {
    throw new HttpError(404, "This link is no longer available.");
  }

  res.set("Cache-Control", "no-store").redirect(302, target);
}
