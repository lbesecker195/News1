import { ZodError } from "zod";

import { HttpError } from "../utils/http-error.mjs";

const wantsJson = req =>
  req.path.startsWith("/api/") || req.path.startsWith("/webhooks/");

export function notFound(req, res) {
  if (wantsJson(req)) {
    return res.status(404).json({ error: "Not found." });
  }

  return res.status(404).render("message", {
    title: "Not found",
    heading: "Page not found",
    message: "The requested page is unavailable."
  });
}

export function errorHandler(error, req, res, next) {
  if (res.headersSent) return next(error);

  const status = error instanceof ZodError
    ? 400
    : error instanceof HttpError
      ? error.status
      : 500;

  const message = error instanceof ZodError
    ? "Invalid input."
    : error instanceof HttpError
      ? error.message
      : "Request failed. Please try again or contact support.";

  /*
   * Only unexpected failures are logged. A 400 or a 404 is the application
   * working as intended and would otherwise drown out the real errors.
   */
  if (status >= 500) {
    console.error(`${req.method} ${req.originalUrl}`, error);
  }

  if (wantsJson(req)) {
    return res.status(status).json({ error: message });
  }

  /*
   * The error page is itself a template render, so a broken template would
   * loop back into this handler. Fall back to plain text if it throws.
   */
  return res.status(status).render("message", {
    title: "Request failed",
    heading: "We couldn't complete that request",
    message
  }, (renderError, html) => {
    if (renderError) {
      console.error("Error page render failed:", renderError);
      return res.type("text/plain").send(message);
    }

    res.send(html);
  });
}
