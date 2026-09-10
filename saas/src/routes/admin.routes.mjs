import express, { Router } from "express";

import * as admin from "../controllers/admin.controller.mjs";

import { asyncHandler as wrap } from "../utils/async-handler.mjs";
import { requireAdmin } from "../middleware/admin.middleware.mjs";
import { requireSameOrigin } from "../middleware/origin.middleware.mjs";
import { adminLoginLimiter } from "../middleware/rate-limit.middleware.mjs";

export const adminRoutes = Router();

/* Staff forms are ordinary posts, so this router parses its own bodies. */
adminRoutes.use(express.urlencoded({ extended: false, limit: "32kb" }));

/* Nothing under /admin should ever be cached or indexed. */
adminRoutes.use((req, res, next) => {
  res.set("Cache-Control", "no-store");
  res.set("X-Robots-Tag", "noindex, nofollow");
  next();
});

adminRoutes.get("/login", admin.showLogin);
adminRoutes.post(
  "/login",
  adminLoginLimiter,
  requireSameOrigin,
  wrap(admin.login)
);

adminRoutes.use(requireAdmin);

adminRoutes.get("/", wrap(admin.dashboard));
adminRoutes.post("/logout", requireSameOrigin, wrap(admin.logout));

adminRoutes.post("/advertisers", requireSameOrigin, wrap(admin.createAdvertiser));
adminRoutes.post("/campaigns", requireSameOrigin, wrap(admin.createCampaign));
adminRoutes.post("/creatives", requireSameOrigin, wrap(admin.createCreative));
adminRoutes.post(
  "/campaigns/:id/status",
  requireSameOrigin,
  wrap(admin.setCampaignStatus)
);
