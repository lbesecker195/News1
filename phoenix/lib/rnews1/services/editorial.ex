defmodule Rnews1.Editorial do
  @moduledoc """
  Writing the journal: one article per section, in every language, with the
  same guarantees the newsletter pipeline gives — source read, written from,
  dropped; measured for verbatim overlap; never covered twice.
  """
  require Logger
  alias Rnews1.{AI, Extract, News, Publications, Stories, StoryPipeline}
  alias Rnews1.Util.{Languages, Overlap, Slug}

  @categories ~w(AI Business Compliance Cosmos Crypto Entertainment Health Science Sports Technology USA World)
  def categories, do: @categories

  @queries %{
    "AI" => "artificial intelligence machine learning research industry",
    "Business" => "business economy markets corporate earnings",
    "Compliance" => "regulatory compliance data breach security enforcement",
    "Cosmos" => "astronomy space telescope cosmology mission",
    "Crypto" => "cryptocurrency bitcoin blockchain digital assets",
    "Entertainment" => "entertainment film television music industry",
    "Health" => "health medicine clinical research public health",
    "Science" => "scientific research discovery study published",
    "Sports" => "sports competition league championship",
    "Technology" => "technology software hardware engineering industry",
    "USA" => "United States national news policy",
    "World" => "world international affairs diplomacy"
  }

  @source_language "en"
  @translation_concurrency 4
  @max_attempts 5

  def source_language, do: @source_language
  def translation_concurrency, do: @translation_concurrency
  def translation_languages, do: Languages.codes() |> Enum.reject(&(&1 == @source_language))

  def match_category(name), do: Enum.find(@categories, &(String.downcase(&1) == String.downcase(to_string(name))))

  @doc "The seed query for one of the archive's original twelve sections."
  def query_for(category), do: Map.get(@queries, category)

  @doc """
  Writes one article for the archive's own section of that name. The archive is
  a publication like any other now; this resolves it and hands over.
  """
  def write_for_category(category, opts \\ []) do
    publication = Keyword.get_lazy(opts, :publication, &Rnews1.Publications.ensure_default/0)

    case Rnews1.Publications.match_section(publication.id, category) do
      nil -> %{category: category, status: "unknown_category"}
      section -> write_for_section(publication, section, opts)
    end
  end

  @doc """
  Writes one article for a section of a publication: discovery through its own
  query, the rewrite, and a row per language the publication runs.
  """
  def write_for_section(publication, section, opts \\ []) do
    category = section.name
    query = section.query

    languages =
      Keyword.get_lazy(opts, :languages, fn ->
        publication.languages |> List.wrap() |> Enum.reject(&(&1 == @source_language))
      end)

    concurrency = Keyword.get(opts, :concurrency, @translation_concurrency)
    dry_run = Keyword.get(opts, :dry_run, false)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case query do
      nil ->
        %{category: category, status: "unknown_category"}

      query ->
        case find_candidates(query) do
          [] ->
            %{category: category, status: "nothing_fresh"}

          candidates ->
            case attempt_candidates(Enum.take(candidates, @max_attempts), category) do
              {:error, attempts} ->
                too_close = Enum.filter(attempts, & &1[:verbatim_run])

                %{
                  category: category,
                  status: if(too_close == [], do: "unreadable", else: "too_close_to_source"),
                  detail: Enum.map_join(attempts, "; ", &"#{&1.source}: #{&1.outcome}"),
                  attempts: length(attempts),
                  verbatim_run: if(too_close != [], do: too_close |> Enum.map(& &1.verbatim_run) |> Enum.max())
                }

              {:ok, candidate, article, written, run} ->
                publish(publication, category, candidate, article, written, run, languages, concurrency, dry_run, now)
            end
        end
    end
  end

  defp attempt_candidates(candidates, category) do
    Enum.reduce_while(candidates, {:error, []}, fn next, {:error, attempts} ->
      fetched = Extract.fetch_article(next.url)

      cond do
        is_nil(fetched) or is_nil(fetched.text) ->
          {:cont, {:error, attempts ++ [%{source: next.source, outcome: (fetched && fetched.method) || "fetch failed"}]}}

        true ->
          case write_article(%{category: category, headline: next.title, publisher: next.source, source: fetched.text}) do
            nil ->
              {:cont, {:error, attempts ++ [%{source: next.source, outcome: "write failed"}]}}

            draft ->
              overlap = Overlap.longest_shared_run(fetched.text, "#{draft.headline} #{draft.standfirst} #{draft.body}", Overlap.verbatim_limit() * 2)

              if overlap.prose >= Overlap.verbatim_limit() do
                {:cont,
                 {:error,
                  attempts ++ [%{source: next.source, outcome: "too close (#{overlap.prose} words: \"#{String.slice(overlap.phrase, 0, 40)}…\")", verbatim_run: overlap.prose}]}}
              else
                {:halt, {:ok, next, fetched, draft, overlap}}
              end
          end
      end
    end)
  end

  defp publish(publication, category, candidate, article, written, run, languages, concurrency, dry_run, now) do
    slug = unique_slug(publication.id, written.headline, category)

    source_row =
      Map.merge(written, %{language: @source_language, fingerprint: candidate.mark, source_url: article.url || candidate.url, source_name: candidate.source})

    translations =
      languages
      |> Task.async_stream(fn language -> translate_article(%{article: written, language: language, category: category}) end,
        max_concurrency: max(1, concurrency),
        timeout: :infinity,
        ordered: true
      )
      |> Enum.zip(languages)
      |> Enum.flat_map(fn
        {{:ok, %{} = t}, language} -> [Map.put(t, :language, language)]
        _ -> []
      end)

    rows = [source_row | translations]

    if dry_run do
      %{category: category, status: "would_publish", slug: slug, headline: written.headline, languages: Enum.map(rows, & &1.language), verbatim_run: run.prose, source_chars: article.chars}
    else
      published =
        Enum.flat_map(rows, fn row ->
          saved =
            Stories.create_editorial(%{
              publication_id: publication.id,
              language: row.language,
              slug: slug,
              translation_key: slug,
              category: category,
              tags: written.tags,
              headline: row.headline,
              standfirst: row.standfirst,
              body: row.body,
              published_at: now,
              issue_date: issue_date(now),
              fingerprint: row[:fingerprint],
              source_url: row[:source_url],
              source_name: row[:source_name],
              verbatim_run: run.prose
            })

          if saved, do: [row.language], else: []
        end)

      %{category: category, status: "published", slug: slug, headline: written.headline, languages: published, verbatim_run: run.prose, source_chars: article.chars}
    end
  end

  # UTC, so a run at either side of midnight files every language under one day.
  defp issue_date(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.to_iso8601()

  defp find_candidates(query) do
    items = News.fetch_topic_items(query: query)

    if items == [] do
      []
    else
      marks = Enum.map(items, &Stories.fingerprint(&1.url))
      covered = Stories.archive_covers(marks)

      items
      |> Enum.zip(marks)
      |> Enum.map(fn {item, mark} -> Map.put(item, :mark, mark) end)
      |> Enum.reject(fn item -> MapSet.member?(covered, item.mark) or StoryPipeline.our_own?(item.url) end)
    end
  end

  # ---- writing ---------------------------------------------------------------------

  @max %{headline: 200, standfirst: 400, body: 20_000}

  def write_article(%{category: category, headline: headline, publisher: publisher, source: source}) do
    instruction =
      Enum.join(
        [
          "You write original news features for a general-interest journal.",
          "",
          "You are given a publisher's article. Report the facts in it in your own",
          "words. This is a rewrite, not a summary: it should stand as its own",
          "piece of writing.",
          "",
          "Produce:",
          "- headline: your own wording, under 80 characters, plain and factual.",
          "- standfirst: one sentence under 35 words saying what the piece is about.",
          "- body: 600-900 words of Markdown. Open with the news, then give the",
          "  context a reader needs to understand why it matters. Use two or three",
          "  '##' subheadings. No H1 — the page supplies the title.",
          "- tags: 5 to 10 lowercase topic tags.",
          "",
          "Rules:",
          "- Write every sentence from scratch. Never reuse the source's phrasing or",
          "  sentence structure. If a sentence of yours could be found in the",
          "  original, rewrite it.",
          "- Quote at most one short phrase, in quotation marks, and only when the",
          "  exact words matter.",
          "- Use only facts present in the article. Never invent figures, dates,",
          "  names, quotes or events.",
          "- Attribute the reporting to the publisher named.",
          "- Do not open with the same sentence or angle as the source.",
          "",
          ~s(Return {"headline":"...","standfirst":"...","body":"...","tags":["..."]})
        ],
        "\n"
      )

    output = AI.json(instruction, %{section: category, publisher: publisher, sourceHeadline: headline, article: source})

    if output["headline"] && output["body"] do
      %{
        headline: output["headline"] |> to_string() |> String.trim() |> String.slice(0, @max.headline),
        standfirst: (output["standfirst"] || "") |> to_string() |> String.trim() |> String.slice(0, @max.standfirst),
        body: output["body"] |> to_string() |> String.trim() |> String.slice(0, @max.body),
        tags: output["tags"] |> List.wrap() |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase())) |> Enum.take(10)
      }
    end
  rescue
    e ->
      Logger.warning("Writing #{category} failed: #{Exception.message(e)}")
      nil
  end

  def translate_article(%{article: article, language: language, category: category}) do
    case Map.get(Languages.names(), language) do
      nil ->
        nil

      target ->
        instruction =
          Enum.join(
            [
              "You translate journalism into #{target.english} (#{target.name}).",
              "",
              "Translate the headline, standfirst and body faithfully and idiomatically —",
              "this should read as though it were written in the target language, not as",
              "a literal rendering.",
              "",
              "Rules:",
              "- Preserve the Markdown exactly: '##' subheadings, '**' emphasis, links.",
              "- Keep every fact, name, figure and date unchanged.",
              "- Do not add, remove or summarise anything.",
              "- Transliterate personal and place names where that is the convention in",
              "  the target language; otherwise leave them as they are.",
              "",
              ~s(Return {"headline":"...","standfirst":"...","body":"..."})
            ],
            "\n"
          )

        output =
          AI.json(instruction, %{section: category, headline: article.headline, standfirst: article.standfirst, body: article.body}, max_retries: 1)

        if output["headline"] && output["body"] do
          %{
            headline: output["headline"] |> to_string() |> String.trim() |> String.slice(0, @max.headline),
            standfirst: (output["standfirst"] || "") |> to_string() |> String.trim() |> String.slice(0, @max.standfirst),
            body: output["body"] |> to_string() |> String.trim() |> String.slice(0, @max.body)
          }
        end
    end
  rescue
    e ->
      Logger.warning("Translating to #{language} failed: #{Exception.message(e)}")
      nil
  end

  # ---- slugs -----------------------------------------------------------------------

  def slugify(text), do: Slug.slugify(text)

  # Taken is per publication: two news sites may each run a "spring-collections"
  # and neither should push the other into a numbered suffix.
  defp unique_slug(publication_id, headline, category) do
    base =
      case slugify(headline) do
        "" -> (case slugify(category), do: ("" -> "story"; s -> s))
        s -> s
      end

    taken? = &Stories.slug_taken?(publication_id, &1)

    if not taken?.(base) do
      base
    else
      Enum.find_value(2..20, fn n -> if not taken?.("#{base}-#{n}"), do: "#{base}-#{n}" end) ||
        "#{base}-#{Integer.to_string(System.os_time(:millisecond), 36)}"
    end
  end

  # ---- backfilling missing locales --------------------------------------------------

  def backfill_translations(opts \\ []) do
    languages = Keyword.get(opts, :languages, Languages.codes())
    limit = Keyword.get(opts, :limit, 25)
    dry_run = Keyword.get(opts, :dry_run, false)

    Stories.missing_translations(%{languages: languages, limit: limit})
    |> Enum.map(fn group ->
      case Stories.source_for(group.translation_key, @source_language) do
        nil ->
          %{key: group.translation_key, status: "no_source", missing: group.missing}

        source when dry_run ->
          %{key: group.translation_key, status: "would_translate", from: source.language, missing: group.missing}

        source ->
          # Only the locales this story's own publication runs. An English-only
          # site must not be quietly translated into the archive's twelve just
          # because the backfill was asked for them.
          wanted = Enum.filter(group.missing, &(&1 in Publications.languages_of(source.publication_id)))

          {added, failed} =
            Enum.reduce(wanted, {[], []}, fn language, {added, failed} ->
              translated = translate_article(%{article: %{headline: source.headline, standfirst: source.standfirst, body: source.body}, language: language, category: source.category})

              saved =
                translated &&
                  Stories.create_editorial(%{
                    publication_id: source.publication_id,
                    language: language,
                    slug: source.slug,
                    translation_key: group.translation_key,
                    category: source.category,
                    tags: source.tags || [],
                    headline: translated.headline,
                    standfirst: translated.standfirst,
                    body: translated.body,
                    published_at: source.published_at,
                    issue_date: source.date_slug,
                    fingerprint: nil,
                    verbatim_run: source.verbatim_run || 0
                  })

              if saved, do: {added ++ [language], failed}, else: {added, failed ++ [language]}
            end)

          %{key: group.translation_key, status: if(added == [], do: "failed", else: "translated"), from: source.language, added: added, failed: failed}
      end
    end)
  end
end
