import { Router } from "express";

import * as site from "../controllers/site.controller.mjs";
import * as auth from "../controllers/auth.controller.mjs";
import * as subscriber from "../controllers/subscriber.controller.mjs";
import * as feed from "../controllers/feed.controller.mjs";
import * as ad from "../controllers/ad.controller.mjs";
import * as editorial from "../controllers/editorial.controller.mjs";

import { asyncHandler as wrap } from "../utils/async-handler.mjs";
import { requireAuthPage } from "../middleware/auth.middleware.mjs";
import { requireSameOrigin } from "../middleware/origin.middleware.mjs";
import {
  loginCompleteLimiter,
  publicFeedLimiter
} from "../middleware/rate-limit.middleware.mjs";

export const siteRoutes = Router();

siteRoutes.get("/", site.home);
siteRoutes.get("/app", wrap(requireAuthPage), site.dashboard);

/* One page, both words: see site.controller.signin. */
siteRoutes.get("/login", site.signin);
siteRoutes.get("/register", site.signin);

siteRoutes.get("/robots.txt", site.robots);
siteRoutes.get("/sitemap.xml", wrap(site.sitemap));

siteRoutes.get("/privacy", site.privacy);
siteRoutes.get("/terms", site.terms);
siteRoutes.get("/health", wrap(site.health));

siteRoutes.get("/login/:token", wrap(auth.showLogin));
siteRoutes.post(
  "/login/:token",
  loginCompleteLimiter,
  requireSameOrigin,
  wrap(auth.completeLogin)
);

siteRoutes.get(
  "/confirm/:token",
  wrap(subscriber.showConfirmation)
);
siteRoutes.post(
  "/confirm/:token",
  requireSameOrigin,
  wrap(subscriber.confirm)
);

siteRoutes.get("/u/:token", wrap(subscriber.showUnsubscribe));

// Intentionally no origin guard: supports Mailgun/mail-client one-click POST.
siteRoutes.post("/u/:token", wrap(subscriber.unsubscribe));

// Public, unauthenticated and cacheable.
siteRoutes.get("/feed/:token.xml", publicFeedLimiter, wrap(feed.rss));
siteRoutes.get("/embed/:token", publicFeedLimiter, wrap(feed.embed));
siteRoutes.get("/news/:token/:id", publicFeedLimiter, wrap(feed.article));

/*
 * Ad tracking. Short paths because they are embedded in every issue, and no
 * rate limit: these are opened by mail clients on the reader's behalf, and
 * throttling them would just lose delivery data.
 */
siteRoutes.get("/a/p/:id.gif", wrap(ad.pixel));
siteRoutes.get("/a/c/:id", wrap(ad.click));

siteRoutes.get("/brief/:id", wrap(feed.brief));
siteRoutes.get("/brief/:id/email", wrap(feed.briefEmail));
siteRoutes.get("/pdf/:id", wrap(feed.pdf));

/*
 * The imported archive, last so that nothing above it can be shadowed: these
 * patterns are the broadest on the site, and the language segment is checked
 * against the twelve we publish in before anything else happens.
 *
 *   /{language}                              the journal index
 *   /{language}/{topic}                      a section
 *   /{language}/{topic}/{slug}               every link the Hugo site published
 *   /{language}/{topic}/{slug}/{yyyy-mm-dd}  canonical
 */
siteRoutes.get("/:language/:topic/:slug/:date", wrap(editorial.article));
siteRoutes.get("/:language/:topic/:slug", wrap(editorial.undatedArticle));
siteRoutes.get("/:language/:topic", wrap(editorial.topic));
siteRoutes.get("/:language", wrap(editorial.index));
