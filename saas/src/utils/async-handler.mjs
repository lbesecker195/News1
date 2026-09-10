/*
 * Express 5 forwards rejected promises to the error handler on its own, but
 * wrapping keeps the behaviour explicit and identical under Express 4.
 */
export const asyncHandler = fn => (req, res, next) =>
  Promise.resolve(fn(req, res, next)).catch(next);
