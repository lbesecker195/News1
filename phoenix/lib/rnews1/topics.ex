defmodule Rnews1.Topics do
  @moduledoc "Crawl topics, leased rather than locked."
  alias Rnews1.DB

  def claim_stale_topic(lease_minutes \\ 10) do
    DB.one(
      """
      UPDATE topics SET refresh_after = now() + ($1 || ' minutes')::interval
      WHERE key = (SELECT key FROM topics WHERE refresh_after <= now() ORDER BY refresh_after LIMIT 1 FOR UPDATE SKIP LOCKED)
      RETURNING key, query, language, COALESCE(items,'[]'::jsonb) AS items
      """,
      [to_string(lease_minutes)]
    )
  end

  # The interval is cast from text rather than bound as one. A bare `$3::interval`
  # makes Postgres report the parameter's type as interval, and Postgrex will then
  # encode only a %Postgrex.Interval{} or %Duration{} — a plain "1 hour" raises
  # DBConnection.EncodeError. Going through text is what the `($n || ' days')`
  # spellings elsewhere in the app are doing implicitly.
  def save_items(key, items, refresh_interval \\ "1 hour") do
    DB.execute(
      "UPDATE topics SET items=$2, refreshed_at=now(), refresh_after=now() + ($3::text)::interval, last_error=NULL WHERE key=$1",
      [key, items, refresh_interval]
    )
  end

  def record_failure(key, message, retry_interval \\ "15 minutes") do
    DB.execute("UPDATE topics SET refresh_after=now() + ($3::text)::interval, last_error=$2 WHERE key=$1", [
      key,
      String.slice(to_string(message), 0, 500),
      retry_interval
    ])
  end

  def park_unused do
    DB.execute("""
    UPDATE topics SET refresh_after = now() + interval '30 days'
    WHERE refresh_after <= now() + interval '1 hour'
      AND NOT EXISTS (SELECT 1 FROM tenants t WHERE t.topic_key = topics.key)
    """)
  end
end
