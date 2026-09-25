defmodule Rnews1.Ads do
  @moduledoc "Ad selection and delivery accounting; targeting is matched in SQL."
  alias Rnews1.DB

  def eligible_creatives(%{slot: slot, issue_date: issue_date} = a) do
    DB.all(
      """
      SELECT cr.id AS creative_id, cr.campaign_id, cr.slot, cr.headline, cr.body, cr.cta, cr.image_url, cr.click_url, cr.weight
      FROM creatives cr
      JOIN campaigns c ON c.id = cr.campaign_id
      JOIN advertisers a ON a.id = c.advertiser_id
      WHERE cr.active AND a.active AND c.status = 'active' AND cr.slot = $1
        AND $2::date BETWEEN c.starts_on AND c.ends_on
        AND (c.total_cap = 0 OR c.impressions < c.total_cap)
        AND (c.daily_cap = 0 OR (SELECT count(*) FROM ad_placements p WHERE p.campaign_id = c.id AND p.issue_date = $2::date) < c.daily_cap)
        AND (c.targeting->'titles' IS NULL
             OR jsonb_array_length(COALESCE(c.targeting->'titles', '[]'::jsonb)) = 0
             OR ($3::text IS NOT NULL AND EXISTS (
               SELECT 1 FROM jsonb_array_elements_text(c.targeting->'titles') AS t(pattern) WHERE lower($3::text) LIKE lower(t.pattern))))
        AND (c.targeting->'industries' IS NULL
             OR jsonb_array_length(COALESCE(c.targeting->'industries', '[]'::jsonb)) = 0
             OR ($4::text IS NOT NULL AND EXISTS (
               SELECT 1 FROM jsonb_array_elements_text(c.targeting->'industries') AS i(name) WHERE lower(i.name) = lower($4::text))))
        AND (c.targeting->'topics' IS NULL
             OR jsonb_array_length(COALESCE(c.targeting->'topics', '[]'::jsonb)) = 0
             OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(c.targeting->'topics') AS k(term) WHERE lower(k.term) = ANY($5::text[])))
      ORDER BY c.cpm_cents DESC, jsonb_array_length(COALESCE(c.targeting->'titles','[]'::jsonb)) DESC, cr.weight DESC, random()
      LIMIT 10
      """,
      [
        slot,
        DB.date(issue_date),
        Map.get(a, :title),
        Map.get(a, :industry),
        Enum.map(Map.get(a, :topic_terms, []), &String.downcase(to_string(&1)))
      ]
    )
  end

  def record_placement(%{campaign_id: campaign_id, creative_id: creative_id, issue_date: issue_date, slot: slot} = a) do
    id =
      DB.value(
        "INSERT INTO ad_placements(campaign_id, creative_id, contact_id, tenant_id, issue_date, slot) VALUES($1,$2,$3,$4,$5,$6) RETURNING id",
        [campaign_id, creative_id, Map.get(a, :contact_id), Map.get(a, :tenant_id), DB.date(issue_date), slot]
      )

    DB.execute("UPDATE campaigns SET impressions = impressions + 1 WHERE id = $1", [campaign_id])
    id
  end

  def record_impression(placement_id) do
    DB.transaction(fn ->
      case DB.one("UPDATE ad_placements SET first_seen = COALESCE(first_seen, now()) WHERE id = $1 RETURNING campaign_id", [placement_id]) do
        nil ->
          false

        %{campaign_id: campaign_id} ->
          DB.execute("INSERT INTO ad_events(placement_id, campaign_id, kind) VALUES($1,$2,'impression')", [placement_id, campaign_id])
          true
      end
    end)
  end

  def record_click(placement_id) do
    DB.transaction(fn ->
      case DB.one(
             """
             UPDATE ad_placements p SET first_click = COALESCE(p.first_click, now())
             FROM creatives cr WHERE p.id = $1 AND cr.id = p.creative_id RETURNING p.campaign_id, cr.click_url
             """,
             [placement_id]
           ) do
        nil ->
          nil

        %{campaign_id: campaign_id, click_url: url} ->
          DB.execute("INSERT INTO ad_events(placement_id, campaign_id, kind) VALUES($1,$2,'click')", [placement_id, campaign_id])
          DB.execute("UPDATE campaigns SET clicks = clicks + 1 WHERE id = $1", [campaign_id])
          url
      end
    end)
  end

  def complete_finished_campaigns do
    DB.execute("""
    UPDATE campaigns SET status = 'completed'
    WHERE status = 'active' AND (ends_on < current_date OR (total_cap > 0 AND impressions >= total_cap))
    """)
  end

  def campaign_report(campaign_id \\ nil) do
    DB.all(
      """
      SELECT c.id, a.name AS advertiser, c.name, c.status, c.starts_on, c.ends_on, c.cpm_cents, c.impressions, c.clicks,
             count(p.id) FILTER (WHERE p.first_seen IS NOT NULL)::int AS confirmed_opens,
             round(c.impressions * c.cpm_cents / 1000.0)::int AS revenue_cents
      FROM campaigns c JOIN advertisers a ON a.id = c.advertiser_id
      LEFT JOIN ad_placements p ON p.campaign_id = c.id
      WHERE ($1::uuid IS NULL OR c.id = $1)
      GROUP BY c.id, a.name ORDER BY c.starts_on DESC
      """,
      [campaign_id]
    )
  end

  def list_advertisers, do: DB.all("SELECT id, name, active FROM advertisers ORDER BY name")

  def platform_totals do
    DB.one("""
    SELECT (SELECT count(*) FROM tenants WHERE billing_status = 'active')::int AS paying_tenants,
           (SELECT count(*) FROM subscribers WHERE state = 'active')::int AS recipients,
           (SELECT count(*) FROM stories WHERE issue_date = current_date)::int AS stories_today,
           (SELECT COALESCE(sum(impressions), 0) FROM campaigns)::int AS impressions,
           (SELECT COALESCE(sum(clicks), 0) FROM campaigns)::int AS clicks,
           (SELECT COALESCE(sum(round(impressions * cpm_cents / 1000.0)), 0) FROM campaigns)::int AS revenue_cents
    """)
  end

  def create_advertiser(name, contact_email) do
    DB.execute("INSERT INTO advertisers(name, contact_email) VALUES($1,$2)", [name, contact_email])
  end

  def create_campaign(input, targeting) do
    DB.execute(
      """
      INSERT INTO campaigns(advertiser_id, name, status, starts_on, ends_on, cpm_cents, daily_cap, total_cap, targeting)
      VALUES($1,$2,'draft',$3,$4,$5,$6,$7,$8)
      """,
      [
        input.advertiser_id,
        input.name,
        DB.date(input.starts_on),
        DB.date(input.ends_on),
        input.cpm_cents,
        input.daily_cap,
        input.total_cap,
        targeting
      ]
    )
  end

  def create_creative(input) do
    DB.execute("INSERT INTO creatives(campaign_id, slot, headline, body, cta, click_url) VALUES($1,$2,$3,$4,$5,$6)", [
      input.campaign_id,
      input.slot,
      input.headline,
      input.body,
      Map.get(input, :cta),
      input.click_url
    ])
  end

  def set_campaign_status(id, status), do: DB.execute("UPDATE campaigns SET status = $2 WHERE id = $1", [id, status])
end
