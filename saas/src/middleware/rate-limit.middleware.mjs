import { rateLimit } from "express-rate-limit";

/*
 * The default store is per-process memory. Running more than one web process
 * multiplies every limit below by the number of processes; swap in a shared
 * store (Redis, Postgres) before scaling out.
 */
function limiter(windowMs, limit) {
  return rateLimit({
    windowMs,
    limit,
    standardHeaders: "draft-7",
    legacyHeaders: false,
    message: { error: "Too many requests. Try again shortly." }
  });
}

/*
 * Requesting a sign-in link sends mail to whatever address was typed, so this
 * is deliberately tight: it is the control that stops the form being used to
 * bomb someone else's inbox.
 */
export const loginLimiter = limiter(60 * 60 * 1000, 5);

/*
 * Following a sign-in link is a different act and needs its own budget.
 * Sharing one with the request above meant a handful of sign-in attempts could
 * lock someone out of an account they had a valid link for.
 *
 * Loose on purpose. The token is 256 bits, single-use and expires in twenty
 * minutes, so brute force is not the threat; this only guards against
 * something pathological.
 */
export const loginCompleteLimiter = limiter(60 * 60 * 1000, 30);
export const apiLimiter = limiter(60 * 1000, 60);
export const inviteLimiter = limiter(60 * 60 * 1000, 20);
export const publicFeedLimiter = limiter(60 * 1000, 120);

/* Staff sign-in is a password form, so it gets the tightest limit. */
export const adminLoginLimiter = limiter(15 * 60 * 1000, 10);
