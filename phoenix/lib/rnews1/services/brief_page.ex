defmodule Rnews1.BriefPage do
  @moduledoc """
  The brief as a landing page. One rendering path serves /brief/:id and feeds
  the PDF, so what a reader prints is exactly what they saw. Every story links
  to its hosted page — an archive article at its /{lang}/{topic}/{slug}/{date}
  URL, a crawled story at /news/:id on the tenant's own site.
  """
  alias Rnews1.{Briefs, Content, Env, Sites}
  alias Rnews1.Util.{Hosts, Languages, Teaser}
  import Rnews1.Util.HTML, only: [safe_url: 1]

  @doc """
  The page. `tracker:` is the analytics tag for a browser, passed by the HTML
  route only — the PDF renderer runs with no network, so it never gets one.
  """
  def render(record, opts \\ []) do
    content = Content.report()
    model = record |> present(content) |> Map.put(:tracker, Keyword.get(opts, :tracker, ""))
    html = Rnews1Web.ReportHTML.render_page(model)
    %{html: html, content: content, model: model}
  end

  def present(record, content \\ Content.report()) do
    issue = Briefs.stories_for(record)
    meta = record[:meta] || %{}
    reader = meta["reader"]
    sections = List.wrap(meta["sections"])
    keywords = List.wrap(record[:keywords])
    language = meta["language"] || "en"

    why_for = Map.new(sections, fn s -> {String.downcase(to_string(s["name"])), s["why"]} end)

    values = %{
      company: (reader && reader["company"]) || record[:company] || "Your company",
      date: record[:date_slug] || "",
      count: to_string(length(issue)),
      reader: (reader && reader["name"]) || "",
      title: (reader && reader["title"]) || ""
    }

    block = Enum.find(content.blocks, &(&1.type == "stories")) || %{}
    shown = issue |> Enum.take(Map.get(block, :limit, 8)) |> Enum.map(&present_story(&1, record, why_for))
    hero = if Map.get(block, :hero, true), do: List.first(shown), else: nil

    %{
      content: content,
      brand: Content.brand(),
      lang: language,
      dir: Languages.direction(language),
      title: "#{Content.fill(content.title, values)} — #{values.company}",
      eyebrow: Content.fill(content.eyebrow, values),
      date: values.date,
      date_long: long_date(values.date, language),
      prepared_for:
        if(reader,
          do: [reader["name"], reader["title"], reader["company"]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(", "),
          else: record[:company]
        ),
      reader: reader,
      sections: sections,
      topics: if(reader, do: Enum.map_join(sections, ", ", & &1["name"]), else: [record[:industry] | keywords] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(", ")),
      stories: shown,
      hero: hero,
      items: if(hero, do: Enum.drop(shown, 1), else: shown),
      count: length(issue),
      columns: Map.get(block, :columns, 2),
      site_url: Env.app_origin(),
      page_url: "#{Env.app_origin()}/brief/#{record.id}",
      generated_at: Date.utc_today() |> Date.to_iso8601()
    }
  end

  defp present_story(story, record, why_for) do
    section = story[:category]

    %{
      id: story.id,
      headline: story.headline,
      standfirst: story[:standfirst] || "",
      teaser: Teaser.first_sentence(story[:standfirst]),
      kicker: section || story[:source_name] || "",
      why: section && Map.get(why_for, String.downcase(section)),
      source: story[:source_name],
      url: hosted_url(story, record)
    }
  end

  def hosted_url(story, record) do
    cond do
      story[:slug] && story[:language] && story[:date_slug] ->
        "#{Env.archive_origin()}/#{Rnews1Web.Archive.path_for(story)}"

      story[:topic_key] && record[:subdomain] && Sites.published?(record) ->
        "#{Hosts.site_origin(record)}/news/#{story.id}"

      true ->
        case safe_url(story[:source_url]) do
          "#" -> nil
          url -> url
        end
    end
  end

  @months ~w(January February March April May June July August September October November December)
  @days ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  @doc "\"Thursday, September 10, 2026\". English regardless of locale — no ICU in OTP."
  def long_date(slug, _language) do
    case Date.from_iso8601(to_string(slug)) do
      {:ok, date} -> "#{Enum.at(@days, Date.day_of_week(date) - 1)}, #{Enum.at(@months, date.month - 1)} #{date.day}, #{date.year}"
      _ -> slug
    end
  end
end
