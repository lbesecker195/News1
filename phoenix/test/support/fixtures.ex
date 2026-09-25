defmodule Rnews1.Fixtures do
  @moduledoc "The seeds the Node tests built: a paying tenant with a story, sessions, archive rows."
  alias Rnews1.{Accounts, Companies, DB, Stories, Subscribers}
  alias Rnews1.Util.Ids

  @topic %{key: Ids.hash("en:acme"), query: "\"Robotics\""}
  def topic, do: @topic

  def new_tenant(email) do
    Accounts.create_login(%{email: email, token_hash: Ids.hash(Ids.token()), url: "u"})
  end

  def tenant_row(id), do: DB.one("SELECT * FROM tenants WHERE id = $1", [id])

  @doc "A paying tenant with a story; published once it has its stakeholders."
  def paid_tenant(opts \\ []) do
    email = Keyword.get(opts, :email, "owner@acme.test")
    name = Keyword.get(opts, :name, "Acme Robotics")
    stakeholders = Keyword.get(opts, :stakeholders, 0)
    plan = Keyword.get(opts, :plan, "enterprise")

    tenant_id = new_tenant(email)
    Companies.save_settings(tenant_id, %{name: name, domain: "acme.test", industry: "Robotics", keywords: ["grippers"], language: "en"}, @topic)
    sub = "I-" <> String.slice(tenant_id, 0, 8)
    DB.execute("UPDATE tenants SET paypal_subscription_id = $2, plan = $3 WHERE id = $1", [tenant_id, sub, plan])
    Companies.sync_subscription(%{subscription_id: sub, status: "active"})

    story =
      Stories.create(%{
        topic_key: @topic.key,
        issue_date: "2026-09-10",
        source_url: "https://example.com/#{tenant_id}",
        source_name: "The Example Times",
        source_title: "Acme ships a robot",
        published_at: ~U[2026-09-10 08:00:00Z],
        headline: "Acme ships a robot",
        standfirst: "What it means for operators.",
        body: "First paragraph.\n\nSecond paragraph.",
        fingerprint: Stories.fingerprint("https://example.com/#{tenant_id}")
      })

    domain = email |> String.split("@") |> List.last()

    for i <- 0..(stakeholders - 1)//1 do
      Subscribers.add_recipient(%{tenant_id: tenant_id, email: "stakeholder#{i}@#{domain}", authorised_by: email})
    end

    %{tenant_id: tenant_id, story: story, tenant: tenant_row(tenant_id)}
  end

  @doc "A browser session, the way following an emailed link produces one: the cookie value."
  def session_for(tenant_id) do
    secret = Ids.token()
    Accounts.create_session_for(tenant_id, Ids.hash(secret))
    secret
  end

  def archive_story(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{language: "en", slug: "a-thing-that-happened", translation_key: "group-1", category: "USA", tags: ["immigration"],
          headline: "Headline in en", standfirst: "A standfirst.", body: "## A heading\n\nA **bold** paragraph with [a link](https://example.com/x).",
          published_at: ~U[2026-08-30 01:11:00Z], issue_date: "2026-08-29", origin: "import"},
        attrs
      )

    DB.one(
      """
      INSERT INTO stories(language, slug, translation_key, category, tags, headline, standfirst, body, published_at, issue_date, origin)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::date,$11) RETURNING *, to_char(issue_date,'YYYY-MM-DD') AS date_slug
      """,
      [attrs.language, attrs.slug, attrs.translation_key, attrs.category, attrs.tags, attrs.headline, attrs.standfirst, attrs.body, attrs.published_at, Date.from_iso8601!(attrs.issue_date), attrs.origin]
    )
  end
end
