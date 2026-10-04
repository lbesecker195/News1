defmodule Rnews1.Campaigns do
  @moduledoc "Outbound campaign safety: stop on our own numbers before Mailgun acts."
  alias Rnews1.DB

  @thresholds %{minimum_sample: 50, complaint_rate: 0.001, bounce_rate: 0.05}
  def thresholds, do: @thresholds

  def health(window_days \\ 7) do
    stats =
      DB.one(
        """
        SELECT count(*) FILTER (WHERE o.status IN ('accepted','unknown'))::int AS sent,
               count(*) FILTER (WHERE o.status = 'failed')::int AS failed,
               count(*) FILTER (WHERE c.opted_out_at >= now() - ($1 || ' days')::interval)::int AS opted_out,
               count(*) FILTER (WHERE c.bounced_at >= now() - ($1 || ' days')::interval)::int AS bounced
        FROM outbox o LEFT JOIN contacts c ON c.id = o.contact_id
        WHERE o.kind IN ('campaign', 'edition') AND o.created_at >= now() - ($1 || ' days')::interval
        """,
        [to_string(window_days)]
      ) || %{sent: 0, failed: 0, opted_out: 0, bounced: 0}

    denominator = max(stats.sent, 1)
    Map.merge(stats, %{window_days: window_days, complaint_rate: stats.opted_out / denominator, bounce_rate: stats.bounced / denominator})
  end

  @doc "nil when sending may continue, or a reason it must not."
  def assert_healthy(window_days \\ 7) do
    h = health(window_days)

    cond do
      h.sent < @thresholds.minimum_sample -> nil
      h.complaint_rate > @thresholds.complaint_rate -> "Complaint rate #{pct(h.complaint_rate)} exceeds #{pct(@thresholds.complaint_rate)}."
      h.bounce_rate > @thresholds.bounce_rate -> "Bounce rate #{pct(h.bounce_rate)} exceeds #{pct(@thresholds.bounce_rate)}."
      true -> nil
    end
  end

  defp pct(rate), do: "#{:erlang.float_to_binary(rate * 100, decimals: 2)}%"
end

defmodule Rnews1.AdSelection do
  @moduledoc "Fills one reader's issue: no campaign takes two slots in the same issue."
  alias Rnews1.{Ads, Env}

  @banner_slots 2
  def banner_slots, do: @banner_slots

  def select_ads(%{contact: contact, tenant_id: tenant_id, issue_date: issue_date, topic_terms: topic_terms}) do
    {sponsored, claimed} = fill("sponsored_story", 1, MapSet.new(), contact, tenant_id, issue_date, topic_terms)
    {banners, _} = fill("banner", @banner_slots, claimed, contact, tenant_id, issue_date, topic_terms)
    %{sponsored: List.first(sponsored), banners: banners}
  end

  defp fill(slot, count, claimed, contact, tenant_id, issue_date, topic_terms) do
    candidates = Ads.eligible_creatives(%{slot: slot, issue_date: issue_date, title: contact && contact[:title], industry: contact && contact[:industry], topic_terms: topic_terms})

    Enum.reduce_while(candidates, {[], claimed}, fn candidate, {chosen, claimed} ->
      cond do
        length(chosen) >= count ->
          {:halt, {chosen, claimed}}

        MapSet.member?(claimed, candidate.campaign_id) ->
          {:cont, {chosen, claimed}}

        true ->
          placement_id =
            Ads.record_placement(%{
              campaign_id: candidate.campaign_id,
              creative_id: candidate.creative_id,
              contact_id: contact && contact[:id],
              tenant_id: tenant_id,
              issue_date: issue_date,
              slot: slot
            })

          {:cont,
           {chosen ++
              [
                %{
                  headline: candidate.headline,
                  body: candidate.body,
                  cta: candidate.cta,
                  image_url: candidate.image_url,
                  click_url: "#{Env.app_origin()}/a/c/#{placement_id}",
                  pixel_url: "#{Env.app_origin()}/a/p/#{placement_id}.gif"
                }
              ], MapSet.put(claimed, candidate.campaign_id)}}
      end
    end)
  end
end
