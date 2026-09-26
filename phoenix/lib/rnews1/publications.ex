defmodule Rnews1.Publications do
  @moduledoc """
  The editorial sites we publish. The archive is one of them — the default —
  and every additional news site on its own domain is another row.

  A publication owns three things that used to be constants: the hostname it is
  served on, the sections it runs, and the languages it publishes in. Nothing
  else about an editorial site varies, so nothing else lives here.
  """
  alias Rnews1.{DB, Env}
  alias Rnews1.Util.Languages

  @default_slug "archive"

  def default_slug, do: @default_slug

  def default, do: DB.one("SELECT * FROM publications WHERE slug = $1", [@default_slug])

  def find_by_hostname(hostname) when is_binary(hostname) do
    DB.one("SELECT * FROM publications WHERE hostname = $1 AND active", [String.downcase(hostname)])
  end

  def find_by_hostname(_), do: nil

  def find_by_slug(slug), do: DB.one("SELECT * FROM publications WHERE slug = $1", [slug])

  def list, do: DB.all("SELECT * FROM publications ORDER BY created_at")

  def list_active, do: DB.all("SELECT * FROM publications WHERE active ORDER BY created_at")

  def sections(publication_id) do
    DB.all(
      "SELECT * FROM publication_sections WHERE publication_id = $1 ORDER BY position, name",
      [publication_id]
    )
  end

  def section_names(publication_id) do
    DB.all("SELECT name FROM publication_sections WHERE publication_id = $1 ORDER BY position, name", [publication_id])
    |> Enum.map(& &1.name)
  end

  @doc "The section, by name, case-insensitively — the {topic} segment of a URL."
  def match_section(publication_id, name) do
    DB.one(
      "SELECT * FROM publication_sections WHERE publication_id = $1 AND lower(name) = lower($2)",
      [publication_id, to_string(name)]
    )
  end

  @doc """
  The archive row, reconciled against the environment. The migration seeds it —
  including its sections, which are the URL contract — with a hostname that
  cannot resolve, because the real one is configuration. This is where it learns
  its own address, and adopts any story written before the column existed.

  Sections are never touched here: a half-finished boot must not be able to
  leave a site with some of its beats missing.
  """
  def ensure_default do
    publication =
      DB.one(
        """
        INSERT INTO publications(slug, name, hostname, languages)
        VALUES($1, $2, $3, $4)
        ON CONFLICT (slug) DO UPDATE SET hostname = EXCLUDED.hostname
        RETURNING *
        """,
        [@default_slug, "Rnews1", Env.archive_host(), Languages.codes()]
      )

    DB.execute(
      "UPDATE stories SET publication_id = $1 WHERE publication_id IS NULL AND origin IN ('import','editorial')",
      [publication.id]
    )

    publication
  end

  @doc """
  A new news site. Languages default to English alone rather than to the
  archive's twelve: every extra locale is another rewrite through OpenAI for
  every article, and that is a decision to make deliberately per site.
  """
  def create(attrs) do
    DB.transaction(fn ->
      publication =
        DB.one(
          """
          INSERT INTO publications(slug, name, hostname, languages, active, tagline)
          VALUES($1, $2, $3, $4, $5, $6)
          ON CONFLICT (slug) DO UPDATE
            SET name = EXCLUDED.name, hostname = EXCLUDED.hostname,
                languages = EXCLUDED.languages, active = EXCLUDED.active,
                tagline = EXCLUDED.tagline
          RETURNING *
          """,
          [
            attrs.slug,
            attrs.name,
            String.downcase(attrs.hostname),
            Map.get(attrs, :languages, ["en"]),
            Map.get(attrs, :active, true),
            Map.get(attrs, :tagline)
          ]
        )

      for {section, index} <- Enum.with_index(Map.get(attrs, :sections, [])) do
        add_section(publication.id, section.name, section.query, index)
      end

      publication
    end)
  end

  def add_section(publication_id, name, query, position \\ 0) do
    DB.one(
      """
      INSERT INTO publication_sections(publication_id, name, query, position)
      VALUES($1, $2, $3, $4)
      ON CONFLICT (publication_id, name) DO UPDATE SET query = EXCLUDED.query, position = EXCLUDED.position
      RETURNING *
      """,
      [publication_id, name, query, position]
    )
  end

  def set_active(id, active) do
    DB.execute("UPDATE publications SET active = $2 WHERE id = $1", [id, active])
  end

  def set_languages(id, languages) do
    DB.execute("UPDATE publications SET languages = $2 WHERE id = $1", [id, languages])
  end

  @doc "The locales one publication runs, for callers holding only a story's id."
  def languages_of(publication_id) do
    case DB.one("SELECT languages FROM publications WHERE id = $1", [publication_id]) do
      %{languages: languages} -> List.wrap(languages)
      _ -> []
    end
  end

  @doc "Every hostname we serve editorially — what the TLS gate vouches for."
  def hostnames, do: DB.all("SELECT hostname FROM publications WHERE active") |> Enum.map(& &1.hostname)
end
