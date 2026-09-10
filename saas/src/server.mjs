import { createApp } from "./app.mjs";
import { pool } from "./config/database.mjs";
import { env, requireEnv, WEB_ENV } from "./config/env.mjs";
import { accessToken, paypalConfigured } from "./config/paypal.mjs";
import { APP } from "./services/platform.service.mjs";

/*
 * Fail at boot, not on the first request that happens to need a credential.
 * Each preflight is reported as a configuration problem with the variable to
 * look at, rather than as an unhandled rejection from deep inside a vendor SDK.
 */
try {
  requireEnv(...WEB_ENV);
} catch (error) {
  console.error(`Startup failed: ${error.message}`);
  process.exit(1);
}

await preflight(
  "connect to Postgres",
  "DATABASE_URL",
  () => pool.query("SELECT 1")
);

/*
 * Authenticating is enough: it proves the shared csuite_finder credentials
 * reach PayPal. The billing plan itself is created lazily on first subscribe,
 * so a cold database does not need a PayPal round trip to boot.
 *
 * Unconfigured is a supported state — everything but subscribing works — so it
 * is a warning, not a failure. Bad credentials are still a failure: they mean
 * someone intended payments to work and they silently would not.
 */
if (paypalConfigured()) {
  await preflight(
    "authenticate with PayPal",
    "PAYPAL_CLIENT_ID / PAYPAL_CLIENT_SECRET",
    accessToken
  );

  /*
   * Live credentials on a non-public origin means real money against return
   * URLs that point at a development machine. Almost always a mistake, and an
   * expensive one to notice late.
   */
  if (env.paypalMode === "live" && !APP.startsWith("https://")) {
    console.warn(
      `WARNING: PayPal is in LIVE mode but APP_ORIGIN is ${APP}. ` +
      "Subscribing will create real billing objects and charge real money, " +
      "and PayPal will return customers to an origin it cannot reach. " +
      "Use sandbox credentials for local development."
    );
  }
} else {
  console.warn(
    "PayPal is not configured; subscribing is disabled. " +
    "Set PAYPAL_CLIENT_ID, PAYPAL_CLIENT_SECRET and PAYPAL_WEBHOOK_ID to enable it."
  );
}

async function preflight(what, variables, check) {
  try {
    await check();
  } catch (error) {
    console.error(
      `Startup failed: could not ${what}.\n` +
      `  ${error.message}\n` +
      `  Check ${variables} in your environment.`
    );

    process.exit(1);
  }
}

const app = createApp();

const server = app.listen(env.port, () => {
  console.log(`Rnews1 listening on port ${env.port} at ${APP}`);
});

let stopping = false;

async function shutdown(signal) {
  if (stopping) return;
  stopping = true;

  console.log(`Received ${signal}; shutting down.`);

  /*
   * A request that never finishes must not hold the deploy open forever.
   * unref() so the timer itself does not keep the process alive.
   */
  const timer = setTimeout(() => {
    console.error("Shutdown timed out; exiting.");
    process.exit(1);
  }, 10_000);

  timer.unref();

  server.close(async () => {
    try {
      await pool.end();
      process.exit(0);
    } catch (error) {
      console.error(error);
      process.exit(1);
    }
  });
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
