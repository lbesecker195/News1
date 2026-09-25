defmodule Rnews1.StoryPipeline do
  @moduledoc """
  The daily story pipeline: three articles a topic, read and then written up
  in our own words. The source is fetched, used to write from, and dropped —
  no copy of anyone's reporting is stored — and the output is measured against
  the source for verbatim overlap before it is kept.
  """
  require Logger
  alias Rnews1.{AI, Env, Extract, News, Sites, Stories}
  alias Rnews1.Util.Overlap

  @stories_per_issue 3
  def stories_per_issue, do: @stories_per_issue

  # ---- our own hosts -------------------------------------------------------------

  defp base_own_hosts do
    [Env.app_origin(), Env.archive_origin(), Env.sites_domain() | Env.own_hosts()]
    |> Enum.map(&normalise_host/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  def own_hosts do
    case :persistent_term.get({__MODULE__, :own_hosts}, nil) do
      nil -> base_own_hosts()
      set -> set
    end
  end

  @doc "Adds every verified custom domain to the own-host set."
  def refresh_own_hosts do
    extra = Sites.verified_hostnames() |> Enum.map(&normalise_host/1) |> Enum.reject(&is_nil/1)
    :persistent_term.put({__MODULE__, :own_hosts}, MapSet.union(base_own_hosts(), MapSet.new(extra)))
  rescue
    e -> Logger.error("Could not load custom domains for own-host check: #{Exception.message(e)}")
  end

  def normalise_host(value) do
    raw = value |> to_string() |> String.trim()

    if raw == "" do
      nil
    else
      uri = if String.contains?(raw, "://"), do: URI.parse(raw), else: URI.parse("https://" <> raw)

      case uri.host do
        host when is_binary(host) and host != "" -> host |> String.downcase() |> String.replace(~r/^www\./, "")
        _ -> nil
      end
    end
  end

  @doc "Matched on host, never on the publisher name a feed supplies. Subdomains count."
  def our_own?(url) do
    case normalise_host(url) do
      nil -> false
      host -> Enum.any?(own_hosts(), fn own -> host == own or String.ends_with?(host, "." <> own) end)
    end
  end

  # ---- the issue -------------------------------------------------------------------

  def build_issue(%{topic_key: topic_key, query: query, language: language, issue_date: issue_date}) do
    refresh_own_hosts()
    existing = Stories.for_issue(topic_key, issue_date)

    if length(existing) >= @stories_per_issue do
      existing
    else
      candidates = News.fetch_topic_items(query: query, language: language)
      original = Enum.reject(candidates, &our_own?(&1.url))
      marks = Enum.map(original, &Stories.fingerprint(&1.url))
      taken = Stories.already_used(topic_key, marks)

      fresh =
        original
        |> Enum.zip(marks)
        |> Enum.map(fn {item, mark} -> Map.put(item, :mark, mark) end)
        |> Enum.reject(&MapSet.member?(taken, &1.mark))
        |> Enum.take(@stories_per_issue - length(existing))

      if fresh == [] do
        existing
      else
        written = rewrite(fresh, language)

        saved =
          Enum.flat_map(written, fn story ->
            row =
              Stories.create(%{
                topic_key: topic_key,
                issue_date: issue_date,
                source_url: story.url,
                source_name: story.source,
                source_title: story.title,
                published_at: parse_dt(story.published),
                headline: story.headline,
                standfirst: story.standfirst,
                body: story.body,
                fingerprint: story.mark,
                resolved_url: story[:resolved_url],
                extraction: story[:extraction] || "headline_only",
                source_chars: story[:source_chars] || 0,
                verbatim_run: story[:verbatim_run] || 0
              })

            if row, do: [row], else: []
          end)

        existing ++ saved
      end
    end
  end

  defp parse_dt(value) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  @languages %{"en" => "English", "es" => "Spanish", "fr" => "French", "de" => "German"}

  # Sequential rather than parallel: three requests a topic is not worth
  # hammering a publisher's origin for.
  defp rewrite(items, language) do
    read =
      Enum.flat_map(items, fn item ->
        article = Extract.fetch_article(item.url)

        if article && article.url && our_own?(article.url) do
          Logger.warning("Skipping our own story, reached via redirect: #{article.url}")
          []
        else
          [
            Map.merge(item, %{
              resolved_url: article && article.url,
              source_text: article && article.text,
              extraction: if(article && article.text, do: article.method, else: (article && article.method) || "headline_only"),
              source_chars: (article && article.chars) || 0
            })
          ]
        end
      end)

    read
    |> write(language)
    |> Enum.map(fn story ->
      if is_nil(story[:source_text]) do
        drop_source(story)
      else
        run = Overlap.longest_shared_run(story.source_text, "#{story.headline} #{story.standfirst} #{story.body}", Overlap.verbatim_limit() * 2)

        if run.prose >= Overlap.verbatim_limit() do
          Logger.warning("Rewrite too close to source (#{run.prose} prose words), falling back to headline: #{inspect(String.slice(run.phrase, 0, 60))}")

          drop_source(%{
            story
            | headline: story.title,
              standfirst: "Reported by #{story.source}.",
              body: fallback_body(story),
              extraction: "rejected_verbatim"
          }
          |> Map.put(:verbatim_run, run.prose))
        else
          drop_source(Map.put(story, :verbatim_run, run.prose))
        end
      end
    end)
  end

  # The publisher's text leaves the process here and is never persisted.
  defp drop_source(story), do: Map.delete(story, :source_text)

  @lengths %{headline: 200, standfirst: 400, body: 4000}

  defp write(items, language) do
    language_name = Map.get(@languages, language, "English")
    any_text = Enum.any?(items, & &1[:source_text])

    instruction =
      [
        "You write short original news items for a business newsletter.",
        "Write in #{language_name}.",
        "",
        "For each article produce:",
        "- headline: your own wording, under 90 characters, no clickbait.",
        "- standfirst: one sentence, under 30 words, saying what this is about.",
        "- body: two or three short paragraphs, 110-180 words, covering what",
        "  happened and why it matters to a business reader in this market.",
        "",
        if(any_text,
          do:
            Enum.join(
              [
                "You are given the publisher's article. Report the facts in it; do not",
                "reproduce its language.",
                "",
                "Rules:",
                "- Write every sentence from scratch. Never reuse the source's phrasing,",
                "  sentence structure, or opening. If a sentence of yours could be found",
                "  in the original, rewrite it.",
                "- Never copy a passage. Quote at most one short phrase, in quotation",
                "  marks, and only when the exact words are the point.",
                "- Use only facts present in the article. Do not add background you were",
                "  not given, and never invent figures, dates, names or quotes.",
                "- Do not reproduce the article's structure paragraph by paragraph.",
                "- Attribute the reporting to the publisher named.",
                "- Where an article is truncated or partial, write only what it supports."
              ],
              "\n"
            ),
          else:
            Enum.join(
              [
                "For any article with no text supplied you have only a headline and a",
                "publisher. You have NOT read it. Write only what can responsibly be",
                "said from that: never state details absent from the headline as fact,",
                "and never claim to have read the article or spoken to anyone."
              ],
              "\n"
            )
        ),
        "",
        ~s(Return {"stories":[{"id":"...","headline":"...","standfirst":"...","body":"..."}]}),
        "covering every id you were given."
      ]
      |> Enum.join("\n")

    try do
      output =
        AI.json(instruction, %{
          articles: Enum.map(items, &%{id: &1.id, headline: &1.title, publisher: &1.source, article: &1[:source_text]})
        })

      by_id = output |> Map.get("stories", []) |> List.wrap() |> Map.new(&{to_string(&1["id"]), &1})

      Enum.map(items, fn item ->
        result = Map.get(by_id, item.id, %{})

        Map.merge(item, %{
          headline: text(result["headline"], item.title, @lengths.headline),
          standfirst: text(result["standfirst"], item.title, @lengths.standfirst),
          body: text(result["body"], fallback_body(item), @lengths.body)
        })
      end)
    rescue
      e ->
        Logger.warning("Story rewrite failed, using headlines: #{Exception.message(e)}")

        Enum.map(items, fn item ->
          Map.merge(item, %{
            headline: item.title,
            standfirst: "Reported by #{item.source}.",
            body: fallback_body(item),
            source_text: nil,
            extraction: "headline_only"
          })
        end)
    end
  end

  defp fallback_body(item), do: "#{item.title} — reported by #{item.source}. Follow the link for the original coverage."

  defp text(value, fallback, max) do
    cleaned = if is_binary(value), do: String.trim(value), else: ""
    String.slice(if(cleaned == "", do: fallback, else: cleaned), 0, max)
  end

  # ---- per-reader running order ----------------------------------------------

  def pick_for_contact(%{contact: contact, topic_key: topic_key, issue_date: issue_date, pool: day_stories}) do
    cached = Stories.find_picks(contact.id, topic_key, issue_date)
    by_id = Map.new(day_stories, &{&1.id, &1})

    ordered = cached && cached.story_ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)

    if ordered && length(ordered) == length(day_stories) do
      ordered
    else
      ordering = choose_order(contact, day_stories)

      Stories.save_picks(%{
        contact_id: contact.id,
        topic_key: topic_key,
        issue_date: issue_date,
        story_ids: Enum.map(ordering.stories, & &1.id),
        reason: ordering.reason,
        personalised: ordering.personalised
      })

      ordering.stories
    end
  end

  defp choose_order(contact, day_stories) do
    unpersonalised = %{stories: day_stories, reason: nil, personalised: false}

    cond do
      is_nil(contact[:title]) and is_nil(contact[:company]) and is_nil(contact[:industry]) -> unpersonalised
      length(day_stories) < 2 -> unpersonalised
      true ->
        instruction =
          Enum.join(
            [
              "You choose which story leads one reader's newsletter.",
              "You are given a reader's professional details and today's stories.",
              "Pick the story most useful to that person in their working week, then",
              "order the rest by how relevant they are to the same person.",
              "Judge only on professional relevance to their role, employer and market.",
              ~s(Return {"order":["<id>","<id>","<id>"],"reason":"<12 words or fewer>"}),
              "using every id exactly once."
            ],
            "\n"
          )

        try do
          output =
            AI.json(instruction, %{
              reader: %{title: contact[:title], company: contact[:company], industry: contact[:industry]},
              stories: Enum.map(day_stories, &%{id: &1.id, headline: &1.headline, standfirst: &1.standfirst})
            })

          by_id = Map.new(day_stories, &{&1.id, &1})
          ordered = output |> Map.get("order", []) |> List.wrap() |> Enum.map(&Map.get(by_id, to_string(&1))) |> Enum.reject(&is_nil/1)
          seen = MapSet.new(ordered, & &1.id)
          ordered = ordered ++ Enum.reject(day_stories, &MapSet.member?(seen, &1.id))

          if length(ordered) != length(day_stories) do
            unpersonalised
          else
            reason = output["reason"]
            %{stories: ordered, reason: if(is_binary(reason), do: reason |> String.trim() |> String.slice(0, 120)), personalised: true}
          end
        rescue
          e ->
            Logger.warning("Personalisation failed for a reader: #{Exception.message(e)}")
            unpersonalised
        end
    end
  end
end
