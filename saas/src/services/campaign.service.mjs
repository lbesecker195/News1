import { pool } from "../config/database.mjs";

/*
 * Outbound campaign safety. Cold outreach is the fastest way to lose a sending
 * domain, so the worker checks these numbers before it sends the next campaign
 * message and stops on its own rather than waiting for Mailgun to act.
 */

export const THRESHOLDS = {
  minimumSample: 50,
  complaintRate: 0.001,
  bounceRate: 0.05
};

export async function campaignHealth(windowDays = 7) {
  const { rows } = await pool.query(
    `SELECT
       count(*) FILTER (
         WHERE o.status IN ('accepted','unknown')
       )::int AS sent,
       count(*) FILTER (WHERE o.status = 'failed')::int AS failed,
       count(*) FILTER (
         WHERE c.opted_out_at >= now() - ($1 || ' days')::interval
       )::int AS opted_out,
       count(*) FILTER (
         WHERE c.bounced_at >= now() - ($1 || ' days')::interval
       )::int AS bounced
     FROM outbox o
     LEFT JOIN contacts c ON c.id = o.contact_id
     WHERE o.kind = 'campaign'
       AND o.created_at >= now() - ($1 || ' days')::interval`,
    [String(windowDays)]
  );

  const stats = rows[0] ?? {
    sent: 0,
    failed: 0,
    opted_out: 0,
    bounced: 0
  };

  const denominator = Math.max(stats.sent, 1);

  return {
    ...stats,
    windowDays,
    complaintRate: stats.opted_out / denominator,
    bounceRate: stats.bounced / denominator
  };
}

/*
 * Returns null when sending may continue, or a reason string when it must not.
 * Below minimumSample there is not enough data for the rates to mean anything.
 */
export async function assertCampaignHealthy(windowDays = 7) {
  const health = await campaignHealth(windowDays);

  if (health.sent < THRESHOLDS.minimumSample) return null;

  if (health.complaintRate > THRESHOLDS.complaintRate) {
    return `Complaint rate ${(health.complaintRate * 100).toFixed(2)}% ` +
      `exceeds ${(THRESHOLDS.complaintRate * 100).toFixed(2)}%.`;
  }

  if (health.bounceRate > THRESHOLDS.bounceRate) {
    return `Bounce rate ${(health.bounceRate * 100).toFixed(2)}% ` +
      `exceeds ${(THRESHOLDS.bounceRate * 100).toFixed(2)}%.`;
  }

  return null;
}
