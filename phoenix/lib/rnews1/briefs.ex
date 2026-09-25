defmodule Rnews1.Briefs do
  @moduledoc "The day's brief: one per tenant per day, plus custom reports."
  alias Rnews1.DB

  def find_unexpired(id) do
    DB.one(
      """
      SELECT b.id, b.tenant_id, b.html, b.has_pdf, b.story_ids, b.meta, b.contact_id,
             to_char(b.issue_date, 'YYYY-MM-DD') AS date_slug,
             t.name AS company, t.domain, t.industry, t.keywords, t.public_token, t.subdomain, t.billing_status, t.topic_key,
             cd.hostname AS custom_hostname,
             (SELECT count(*)::int FROM subscribers s WHERE s.tenant_id = t.id AND s.state <> 'unsubscribed') AS stakeholder_count
      FROM briefs b
      LEFT JOIN tenants t ON t.id = b.tenant_id
      LEFT JOIN tenant_domains cd ON cd.tenant_id = t.id AND cd.verified_at IS NOT NULL
      WHERE b.id=$1 AND b.expires_at>now()
      """,
      [id]
    )
  end

  @doc "The stories in a brief, in the order they were selected."
  def stories_for(%{story_ids: ids}) when is_list(ids) and ids != [] do
    rows = DB.all("SELECT *, to_char(issue_date, 'YYYY-MM-DD') AS date_slug FROM stories WHERE id = ANY($1::uuid[])", [ids])
    by_id = Map.new(rows, &{&1.id, &1})
    ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
  end

  def stories_for(_), do: []

  def create(%{issue_date: issue_date} = a) do
    DB.value(
      "INSERT INTO briefs(tenant_id, html, story_ids, issue_date, contact_id, meta) VALUES($1,$2,$3::uuid[],$4::date,$5,$6) RETURNING id",
      [
        Map.get(a, :tenant_id),
        Map.get(a, :html, ""),
        Map.get(a, :story_ids, []),
        DB.date(issue_date),
        Map.get(a, :contact_id),
        Map.get(a, :meta, %{})
      ]
    )
  end

  def mark_pdf_written(id), do: DB.execute("UPDATE briefs SET has_pdf=true WHERE id=$1", [id])

  def delete_expired(limit \\ 500) do
    DB.all("DELETE FROM briefs WHERE id IN (SELECT id FROM briefs WHERE expires_at<=now() LIMIT $1) RETURNING id, has_pdf", [
      limit
    ])
  end
end
