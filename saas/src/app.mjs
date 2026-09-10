import express from "express";
import helmet from "helmet";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { env } from "./config/env.mjs";
import { brandContent } from "./config/content.mjs";
import { asyncHandler as wrap } from "./utils/async-handler.mjs";
import { APP } from "./services/platform.service.mjs";

import { apiRoutes } from "./routes/api.routes.mjs";
import { siteRoutes } from "./routes/site.routes.mjs";
import { adminRoutes } from "./routes/admin.routes.mjs";

import {
  paypalWebhookRoutes,
  mailgunWebhookRoutes
} from "./routes/webhook.routes.mjs";

import { attachSession } from "./middleware/auth.middleware.mjs";

import {
  notFound,
  errorHandler
} from "./middleware/error.middleware.mjs";

const directory = path.dirname(fileURLToPath(import.meta.url));

export function createApp() {
  const app = express();

  /*
   * Only trust a proxy when one is actually in front, or a client can spoof
   * X-Forwarded-For and defeat every per-IP rate limit below.
   */
  if (env.trustProxy) {
    app.set("trust proxy", 1);
  }

  app.disable("x-powered-by");
  app.set("etag", "strong");

  app.set("view engine", "ejs");
  app.set("views", path.join(directory, "views"));

  app.locals.appOrigin = APP;
  app.locals.supportEmail = env.supportEmail;
  app.locals.title = "Rnews1";
  app.locals.indexable = false;

  /*
   * Brand copy lives in content.json alongside the report's, so the name and
   * the line that explains it are edited in one place rather than in markup.
   * Read per request in development; the file's mtime gates the re-read.
   */
  app.use((req, res, next) => {
    res.locals.brand = brandContent();
    next();
  });

  app.use(helmet({
    contentSecurityPolicy: {
      directives: {
        "script-src": ["'self'"],
        "style-src": ["'self'", "'unsafe-inline'"],
        "img-src": ["'self'", "data:"],
        "frame-ancestors": ["'self'"],
        "form-action": ["'self'"],
        /* No cross-origin requests are made from any page. */
        "connect-src": ["'self'"]
      }
    },
    /* The embed is framed by customers; see feed.controller.mjs. */
    crossOriginResourcePolicy: { policy: "cross-origin" },
    referrerPolicy: { policy: "strict-origin-when-cross-origin" }
  }));

  /*
   * Both webhook routers parse their own JSON body, so they are mounted before
   * the application-wide parsers and stay independent of them.
   */
  app.use("/webhooks/paypal", paypalWebhookRoutes);
  app.use("/webhooks/mailgun", mailgunWebhookRoutes);

  app.use(express.json({ limit: "64kb" }));
  app.use(express.urlencoded({
    extended: false,
    limit: "16kb"
  }));

  /*
   * Cache hard in production, not at all in development: a stale stylesheet
   * that survives an edit for an hour is a genuinely confusing way to lose
   * time. ETags still spare the bytes when nothing changed.
   */
  app.use(express.static(
    path.resolve(directory, "../public"),
    {
      maxAge: app.get("env") === "production" ? "1h" : 0,
      etag: true,
      index: false,
      redirect: false
    }
  ));

  app.use("/api", apiRoutes);
  app.use("/admin", adminRoutes);

  /*
   * Page routes only: the header and footer offer the dashboard to a
   * signed-in visitor and the sign-in page to everyone else. The API answers
   * with its own 401 and needs none of this.
   */
  app.use(wrap(attachSession), siteRoutes);

  app.use(notFound);
  app.use(errorHandler);

  return app;
}
