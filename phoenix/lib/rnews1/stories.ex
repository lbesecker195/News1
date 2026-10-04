defmodule Rnews1.Stories do
  @moduledoc """
  Stories we have written: the newsletter's crawl stories, the imported Hugo
  archive, and the articles the writer publishes now.
  """
  alias Rnews1.DB
  alias Rnews1.Util.Languages

  @archive_origins ["import", "editorial"]
  def archive_origins, do: @archive_origins

  def languages, do: Languages.codes()
  def language?(value), do: Languages.language?(to_string(value))

  @doc "Derived from the source URL with tracking parameters stripped."
  def fingerprint(url) do
    normalised = url |> to_string() |> String.trim() |> String.downcase()

    normalised =
      case URI.new(normalised) do
        {:ok, %URI{host: host} = uri} when is_binary(host) ->
          query =
            (uri.query || "")
            |> URI.decode_query()
            |> Enum.reject(fn {key, _} -> Regex.match?(~r/^(utm_|oc$|ved$|usg$|gclid$|fbclid$)/, key) end)
            |> Map.new()

          search = if map_size(query) == 0, do: "", else: "?" <> URI.encode_query(query)
          String.replace("#{host}#{uri.path || ""}#{search}", ~r/\/+$/, "")

        _ ->
          normalised
      end

    :crypto.hash(:sha256, normalised) |> Base.encode16(case: :lower)
  end

  def already_used(_topic_key, []), do: MapSet.new()

  def already_used(topic_key, fingerprints) do
    DB.all("SELECT fingerprint FROM stories WHERE topic_key = $1 AND fingerprint = ANY($2::text[])", [
      topic_key,
      fingerprints
    ])
    |> MapSet.new(& &1.fingerprint)
  end

  @doc "Writes one crawl story; nil when this topic already has that article."
  def create(attrs) do
    DB.one(
      """
      INSERT INTO stories(topic_key, issue_date, source_url, source_name, source_title,
        published_at, headline, standfirst, body, fingerprint, resolved_url, extraction, source_chars, verbatim_run)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
      ON CONFLICT(topic_key, fingerprint) DO NOTHING
      RETURNING *
      """,
      [
        attrs.topic_key,
        DB.date(attrs.issue_date),
        attrs.source_url,
        attrs.source_name,
        attrs.source_title,
        attrs.published_at,
        attrs.headline,
        attrs.standfirst,
        attrs.body,
        attrs.fingerprint,
        Map.get(attrs, :resolved_url),
        Map.get(attrs, :extraction, "headline_only"),
        Map.get(attrs, :source_chars, 0),
        Map.get(attrs, :verbatim_run, 0)
      ]
    )
  end

  def for_issue(topic_key, issue_date) do
    DB.all("SELECT * FROM stories WHERE topic_key = $1 AND issue_date = $2::date ORDER BY created_at", [
      topic_key,
      DB.date(issue_date)
    ])
  end

  def recent_for_topic(topic_key, limit \\ 8) do
    DB.all("SELECT * FROM stories WHERE topic_key = $1 ORDER BY issue_date DESC, created_at DESC LIMIT $2", [
      topic_key,
      limit
    ])
  end

  def find_by_id(id), do: DB.one("SELECT * FROM stories WHERE id = $1", [id])

  def save_picks(%{contact_id: contact_id, topic_key: topic_key, issue_date: issue_date, story_ids: story_ids} = a) do
    DB.one(
      """
      INSERT INTO newsletter_picks(contact_id, topic_key, issue_date, story_ids, reason, personalised)
      VALUES($1,$2,$3::date,$4::uuid[],$5,$6)
      ON CONFLICT (contact_id, topic_key, issue_date) DO UPDATE
        SET story_ids = EXCLUDED.story_ids, reason = EXCLUDED.reason, personalised = EXCLUDED.personalised
      RETURNING *
      """,
      [contact_id, topic_key, DB.date(issue_date), story_ids, Map.get(a, :reason), Map.get(a, :personalised, false)]
    )
  end

  def find_picks(contact_id, topic_key, issue_date) do
    DB.one("SELECT * FROM newsletter_picks WHERE contact_id = $1 AND topic_key = $2 AND issue_date = $3::date", [
      contact_id,
      topic_key,
      DB.date(issue_date)
    ])
  end

  # ---- editorial content ----------------------------------------------------

  # Every archive read is scoped to one publication. A site must never show
  # another site's stories, and the hostname a request arrived on is the only
  # thing that says which one it is — so the id is a required argument rather
  # than an option with a default that could silently widen a query.

  def find_editorial(%{publication_id: publication_id, language: language, slug: slug}) do
    DB.one(
      """
      SELECT *, to_char(issue_date, 'YYYY-MM-DD') AS date_slug FROM stories
      WHERE origin = ANY($4) AND publication_id = $3 AND language = $1 AND slug = $2
      """,
      [language, slug, publication_id, @archive_origins]
    )
  end

  def translations_of(_publication_id, nil), do: []

  def translations_of(publication_id, translation_key) do
    DB.all(
      """
      SELECT language, slug, category, headline, to_char(issue_date, 'YYYY-MM-DD') AS date_slug
      FROM stories WHERE origin = ANY($3) AND publication_id = $2 AND translation_key = $1 ORDER BY language
      """,
      [translation_key, publication_id, @archive_origins]
    )
  end

  def list_editorial(%{publication_id: publication_id, language: language} = opts) do
    DB.all(
      """
      SELECT id, language, slug, category, headline, standfirst, to_char(issue_date, 'YYYY-MM-DD') AS date_slug
      FROM stories
      WHERE origin = ANY($5) AND publication_id = $6 AND language = $1
        AND ($2::text IS NULL OR lower(category) = lower($2))
      ORDER BY published_at DESC LIMIT $3 OFFSET $4
      """,
      [
        language,
        Map.get(opts, :category),
        Map.get(opts, :limit, 30),
        Map.get(opts, :offset, 0),
        @archive_origins,
        publication_id
      ]
    )
  end

  @doc "One day's stories for a publication, newest first: a daily edition's contents."
  def editorial_on(publication_id, language, date, limit) do
    DB.all(
      """
      SELECT id, language, slug, category, headline, standfirst, to_char(issue_date, 'YYYY-MM-DD') AS date_slug
      FROM stories
      WHERE origin = ANY($5) AND publication_id = $1 AND language = $2 AND issue_date = $3::date
      ORDER BY published_at DESC LIMIT $4
      """,
      [publication_id, language, DB.date(date), limit, @archive_origins]
    )
  end

  @doc "The most recent day a publication published anything in this language."
  def latest_editorial_date(publication_id, language) do
    DB.value(
      """
      SELECT to_char(max(issue_date), 'YYYY-MM-DD') FROM stories
      WHERE origin = ANY($3) AND publication_id = $1 AND language = $2
      """,
      [publication_id, language, @archive_origins]
    )
  end

  @doc """
  The week's highlight: of the stories filed in the seven days before `date`,
  the one most clicked through to on the publication's own site, ties going to
  the newer.

  click_events records link and button clicks, not page views: `path` is the
  page a click happened ON and `target` is where it went. So a click-through to
  a story is a `link` whose target is that story's path — counting `path` would
  measure clicks made while already reading it, which is not the same thing.
  The table carries no identifier, so this is a count and nothing more.

  With no click-throughs at all — most weeks, until there is traffic — it
  degrades to the most recent story of the week rather than to nothing.
  """
  def week_highlight(publication_id, language, date, host) do
    DB.one(
      """
      SELECT s.id, s.language, s.slug, s.category, s.headline, s.standfirst,
             to_char(s.issue_date, 'YYYY-MM-DD') AS date_slug,
             (SELECT count(*)::int FROM click_events c
              WHERE c.kind = 'link' AND c.host = $4 AND c.occurred_at > now() - interval '7 days'
                AND c.target = '/' || s.language || '/' || lower(s.category) || '/' || s.slug || '/'
                               || to_char(s.issue_date, 'YYYY-MM-DD')) AS reads
      FROM stories s
      WHERE s.origin = ANY($5) AND s.publication_id = $1 AND s.language = $2
        AND s.issue_date >= $3::date - 7 AND s.issue_date < $3::date
      ORDER BY reads DESC, s.published_at DESC
      LIMIT 1
      """,
      [publication_id, language, DB.date(date), host, @archive_origins]
    )
  end

  def editorial_categories(publication_id, language) do
    DB.all(
      """
      SELECT category, count(*)::int AS n FROM stories
      WHERE origin = ANY($2) AND publication_id = $3 AND language = $1 AND category IS NOT NULL
      GROUP BY category ORDER BY category
      """,
      [language, @archive_origins, publication_id]
    )
  end

  def all_editorial(publication_id, limit \\ 5000) do
    DB.all(
      """
      SELECT language, slug, category, translation_key, to_char(issue_date, 'YYYY-MM-DD') AS date_slug
      FROM stories WHERE origin = ANY($2) AND publication_id = $3 ORDER BY published_at DESC LIMIT $1
      """,
      [limit, @archive_origins, publication_id]
    )
  end

  # These two feed the "continue reading" block under an article. They are
  # scoped like every other archive read: an article on one site must never
  # offer, or link to, a story belonging to another.

  def related_to(%{publication_id: publication_id, language: language, category: category, exclude_id: exclude_id} = opts) do
    DB.all(
      """
      SELECT id, language, slug, category, headline, standfirst,
             to_char(issue_date, 'YYYY-MM-DD') AS date_slug, length(body) AS body_length
      FROM stories
      WHERE origin = ANY($5) AND publication_id = $6 AND language = $1
        AND lower(category) = lower($2) AND id <> $3
      ORDER BY issue_date DESC, created_at DESC LIMIT $4
      """,
      [language, category || "", exclude_id, Map.get(opts, :limit, 3), @archive_origins, publication_id]
    )
  end

  def also_in_language(%{publication_id: publication_id, language: language, exclude_ids: exclude_ids} = opts) do
    DB.all(
      """
      SELECT id, language, slug, category, headline, standfirst,
             to_char(issue_date, 'YYYY-MM-DD') AS date_slug, length(body) AS body_length
      FROM stories
      WHERE origin = ANY($4) AND publication_id = $5 AND language = $1 AND NOT (id = ANY($2::uuid[]))
      ORDER BY issue_date DESC, created_at DESC LIMIT $3
      """,
      [language, exclude_ids, Map.get(opts, :limit, 3), @archive_origins, publication_id]
    )
  end

  def archive_covers([]), do: MapSet.new()

  def archive_covers(fingerprints) do
    DB.all("SELECT DISTINCT fingerprint FROM stories WHERE origin = ANY($2) AND fingerprint = ANY($1::text[])", [
      fingerprints,
      @archive_origins
    ])
    |> MapSet.new(& &1.fingerprint)
  end

  @doc "One language of one article. The URL date is given explicitly, never derived."
  def create_editorial(attrs) do
    DB.one(
      """
      INSERT INTO stories(language, slug, translation_key, category, tags,
        headline, standfirst, body, published_at, issue_date,
        fingerprint, source_url, source_name, verbatim_run, publication_id, origin)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::timestamptz,$14::date,$10,$11,$12,$13,$15,'editorial')
      ON CONFLICT (publication_id, language, slug) WHERE slug IS NOT NULL DO NOTHING
      RETURNING *
      """,
      [
        attrs.language,
        attrs.slug,
        attrs.translation_key,
        attrs.category,
        Map.get(attrs, :tags, []),
        attrs.headline,
        attrs.standfirst,
        attrs.body,
        attrs.published_at,
        Map.get(attrs, :fingerprint),
        Map.get(attrs, :source_url),
        Map.get(attrs, :source_name),
        Map.get(attrs, :verbatim_run, 0),
        DB.date(attrs.issue_date),
        attrs.publication_id
      ]
    )
  end

  def slug_taken?(publication_id, slug) do
    DB.one("SELECT 1 AS x FROM stories WHERE publication_id = $1 AND slug = $2 LIMIT 1", [publication_id, slug]) != nil
  end

  def missing_translations(%{languages: languages} = opts) do
    DB.all(
      """
      SELECT translation_key, array_agg(language ORDER BY language) AS present,
             min(category) AS category, min(slug) AS slug
      FROM stories WHERE origin = ANY($1) AND translation_key IS NOT NULL
      GROUP BY translation_key
      HAVING NOT (array_agg(language) @> $2::text[])
      ORDER BY min(issue_date) DESC LIMIT $3
      """,
      [@archive_origins, languages, Map.get(opts, :limit, 50)]
    )
    |> Enum.map(fn row -> Map.put(row, :missing, Enum.reject(languages, &(&1 in row.present))) end)
  end

  def source_for(translation_key, preferred \\ "en") do
    DB.one(
      """
      SELECT *, to_char(issue_date, 'YYYY-MM-DD') AS date_slug FROM stories
      WHERE origin = ANY($1) AND translation_key = $2
      ORDER BY (language = $3) DESC, created_at LIMIT 1
      """,
      [@archive_origins, translation_key, preferred]
    )
  end

  def recent_by_section(%{sections: sections} = opts) when is_list(sections) and sections != [] do
    DB.all(
      """
      SELECT * FROM (
        SELECT s.*, to_char(s.issue_date, 'YYYY-MM-DD') AS date_slug,
               row_number() OVER (PARTITION BY lower(s.category) ORDER BY s.issue_date DESC, s.created_at DESC) AS rank
        FROM stories s
        WHERE s.origin = ANY($1) AND s.language = $2 AND lower(s.category) = ANY($3::text[])
      ) ranked WHERE rank <= $4 ORDER BY issue_date DESC, created_at DESC
      """,
      [
        @archive_origins,
        Map.get(opts, :language, "en"),
        Enum.map(sections, &String.downcase(to_string(&1))),
        Map.get(opts, :per_section, 2)
      ]
    )
  end

  def recent_by_section(_), do: []

  @doc """
  Upsert for the Hugo import: re-running updates in place. The conflict target
  names the publication because that is the unique index there is — the global
  one on (language, slug) went when a slug became unique per publication.
  """
  def upsert_import(article) do
    DB.execute(
      """
      INSERT INTO stories(publication_id, language, slug, translation_key, category, tags, headline, standfirst, body, published_at, issue_date, origin)
      VALUES($10,$1,$2,$3,$4,$5,$6,$7,$8,$9::timestamptz,$9::timestamptz::date,'import')
      ON CONFLICT (publication_id, language, slug) WHERE slug IS NOT NULL
      DO UPDATE SET translation_key = EXCLUDED.translation_key, category = EXCLUDED.category, tags = EXCLUDED.tags,
        headline = EXCLUDED.headline, standfirst = EXCLUDED.standfirst, body = EXCLUDED.body,
        published_at = EXCLUDED.published_at, issue_date = EXCLUDED.issue_date
      """,
      [
        article.language,
        article.slug,
        article.translation_key,
        article.category,
        article.tags,
        article.title,
        article.description,
        article.body,
        article.published_at,
        Map.get_lazy(article, :publication_id, fn -> Rnews1.Publications.ensure_default().id end)
      ]
    )
  end
end
