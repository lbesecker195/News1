import { Router } from "express";

import * as auth from "../controllers/auth.controller.mjs";
import * as company from "../controllers/company.controller.mjs";
import * as subscriber from "../controllers/subscriber.controller.mjs";
import * as billing from "../controllers/billing.controller.mjs";

import { asyncHandler as wrap } from "../utils/async-handler.mjs";
import { requireAuth } from "../middleware/auth.middleware.mjs";
import { protectMutations } from "../middleware/origin.middleware.mjs";

import {
  apiLimiter,
  loginLimiter,
  inviteLimiter
} from "../middleware/rate-limit.middleware.mjs";

export const apiRoutes = Router();

apiRoutes.use(apiLimiter);
apiRoutes.use(protectMutations);

// Public authentication endpoint.
apiRoutes.post("/login", loginLimiter, wrap(auth.requestLogin));

// Everything below requires a valid session.
apiRoutes.use(requireAuth);

apiRoutes.post("/logout", wrap(auth.logout));

apiRoutes.get("/me", wrap(company.me));
apiRoutes.post("/company", wrap(company.save));
apiRoutes.post("/suggest", wrap(company.suggest));
apiRoutes.get("/preview", wrap(company.preview));

apiRoutes.post(
  "/subscribers",
  inviteLimiter,
  wrap(subscriber.add)
);
apiRoutes.delete("/subscribers", wrap(subscriber.remove));

apiRoutes.post("/checkout", wrap(billing.checkout));
apiRoutes.post("/cancel", wrap(billing.cancel));
