/*
 * Every module below config/env.mjs reads the environment at import time, so
 * this must be imported before anything else in a test file.
 */
process.env.DATABASE_URL ||= "postgres://user:pass@127.0.0.1:5432/rnews1_test";
process.env.APP_ORIGIN ||= "https://rnews1.test";
process.env.SUPPORT_EMAIL ||= "support@rnews1.test";
process.env.OPENAI_API_KEY ||= "sk-test";
process.env.MAILGUN_API_KEY ||= "key-test";
process.env.MAILGUN_DOMAIN ||= "mg.rnews1.test";
process.env.MAILGUN_FROM ||= "Rnews1 <briefings@mg.rnews1.test>";
process.env.MAILGUN_WEBHOOK_SIGNING_KEY ||= "signing-key";
process.env.PAYPAL_MODE ||= "sandbox";
process.env.PAYPAL_CLIENT_ID ||= "client-placeholder";
process.env.PAYPAL_CLIENT_SECRET ||= "secret-placeholder";
process.env.PAYPAL_WEBHOOK_ID ||= "WH-PLACEHOLDER";
process.env.BUSINESS_ADDRESS ||= "1 Test St, Springfield, CA 90000";
process.env.TREG_TOKEN ||= "treg-test-token";
process.env.NEWS_PROVIDER ||= "exa";
