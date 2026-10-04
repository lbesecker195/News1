defmodule Rnews1.Editions do
  @moduledoc """
  Assembles a publication's daily newsletter edition.

  An edition is one day: that day's stories, in English, from one publication,
  plus the highlight of the week before it. Every publication gets the same
  template and nothing else in common — its own name, tagline and host, its own
  stories, and links that land on its own site.
  """
  alias Rnews1.{DB, Env, Stories}
  alias Rnews1.Util.Hosts

  # Editions are sent in English and link to the /en versions of the stories,
  # whatever else a publication runs. The template's own copy is English too, so
  # a mixed-language edition could not read as one thing.
  @language "en"
  @also 6

  @doc """
  The edition for one publication and one day.

  `:date` is the day to send (`"YYYY-MM-DD"`); left out, it is the most recent
  day the publication published anything, which is what the web version shows.
  With no `:unsubscribe_url` it is the web version: no unsubscribe line, and a
  footer that says so instead of claiming the reader subscribed.

  Returns nil when that day has nothing in it, so a sender can skip a day
  rather than mail an empty edition.
  """
  def build(publication, opts \\ []) do
    date =
      Keyword.get_lazy(opts, :date, fn ->
        Stories.latest_editorial_date(publication.id, @language)
      end)

    case date && Stories.editorial_on(publication.id, @language, date, @also + 1) do
      rows when is_list(rows) and rows != [] ->
        assemble(publication, date, rows, opts)

      _ ->
        nil
    end
  end

  def language, do: @language

  defp assemble(publication, date, [lead | also], opts) do
    origin = Hosts.publication_origin(publication)
    highlight = Stories.week_highlight(publication.id, @language, date, publication.hostname)

    %{
      publication: publication,
      origin: origin,
      app_origin: Env.app_origin(),
      date: long_date(date),
      address: Env.business_address(),
      lead: present_lead(publication.id, origin, lead),
      also: Enum.map(also, &present(origin, &1)),
      highlight: highlight && present(origin, highlight),
      web_url: origin <> "/newsletter",
      unsubscribe_url: Keyword.get(opts, :unsubscribe_url),
      reason: Keyword.get(opts, :reason, :subscribed),
      referral: Keyword.get(opts, :referral)
    }
  end

  # Formatted by Postgres, never by Elixir: the same rule as every story URL, so
  # the masthead can never disagree with the day the stories are filed under.
  defp long_date(date) do
    DB.value("SELECT to_char($1::date, 'FMDay FMDD FMMonth YYYY')", [DB.date(date)])
  end

  defp present(origin, row) do
    %{
      section: row.category || "News",
      headline: row.headline,
      standfirst: row.standfirst,
      url: origin <> "/" <> Rnews1Web.Archive.path_for(row)
    }
  end

  defp present_lead(publication_id, origin, row) do
    story =
      Stories.find_editorial(%{
        publication_id: publication_id,
        language: @language,
        slug: row.slug
      })

    origin
    |> present(row)
    |> Map.put(:paragraph, opening_paragraph(story && story.body))
  end

  @doc """
  The first paragraph of a story body, as plain text. The body is Markdown, so
  headings are skipped and emphasis and link syntax are dropped — an inbox would
  show the asterisks and brackets literally.
  """
  def opening_paragraph(nil), do: nil

  def opening_paragraph(body) do
    body
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))
    |> case do
      nil ->
        nil

      text ->
        text
        |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/, "\\1")
        |> String.replace(~r/(\*\*|__|\*|_)(.+?)\1/, "\\2")
        |> String.replace(~r/\s+/, " ")
    end
  end
end
