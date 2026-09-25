defmodule Rnews1.Clicks do
  @moduledoc "Click events: what gets clicked, never who clicked it."
  alias Rnews1.DB

  @retain_days 120
  def retain_days, do: @retain_days

  def record([]), do: 0

  def record(rows) do
    columns = 8

    values =
      rows
      |> Enum.with_index()
      |> Enum.map_join(",", fn {_, index} ->
        base = index * columns
        "(" <> Enum.map_join(1..columns, ",", &"$#{base + &1}") <> ")"
      end)

    params =
      Enum.flat_map(rows, fn row ->
        [
          Map.get(row, :tenant_id),
          row.host,
          row.path,
          row.kind,
          Map.get(row, :target),
          Map.get(row, :label),
          Map.get(row, :external, false),
          Map.get(row, :language)
        ]
      end)

    DB.execute("INSERT INTO click_events(tenant_id, host, path, kind, target, label, external, language) VALUES #{values}", params)
  end

  def prune(days \\ @retain_days) do
    DB.execute("DELETE FROM click_events WHERE occurred_at < now() - ($1 || ' days')::interval", [to_string(days)])
  end

  def top_targets(opts \\ []) do
    DB.all(
      """
      SELECT path, kind, target, label, external, count(*)::int AS clicks, max(occurred_at) AS last_click
      FROM click_events
      WHERE occurred_at > now() - ($3 || ' days')::interval
        AND ($1::uuid IS NULL OR tenant_id = $1) AND ($2::text IS NULL OR host = $2)
      GROUP BY path, kind, target, label, external
      ORDER BY clicks DESC, last_click DESC LIMIT $4
      """,
      [Keyword.get(opts, :tenant_id), Keyword.get(opts, :host), to_string(Keyword.get(opts, :days, 30)), Keyword.get(opts, :limit, 50)]
    )
  end
end
