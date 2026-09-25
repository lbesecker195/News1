defmodule Rnews1Web.ArchiveController do
  @moduledoc "The editorial archive, served at ARCHIVE_ORIGIN; the app host redirects here."
  use Rnews1Web, :controller
  alias Rnews1.{Content, Env, Stories}
  alias Rnews1.Util.{Languages, Markdown, ReadingTime}
  alias Rnews1Web.Archive

  @page_size 24
  @date ~r/^\d{4}-\d{2}-\d{2}$/

  plug :put_brand
  plug :archive_redirect when action in [:article, :undated_article, :topic, :index]

  defp put_brand(conn, _), do: conn |> assign(:brand, Content.brand()) |> assign(:app_origin, Env.app_origin())

  # On the app host the archive paths 301 to www — unless the archive shares the host.
  defp archive_redirect(conn, _) do
    archive_on_app = Env.archive_host() == Env.app_host()

    if conn.assigns[:host_kind] != :archive and not archive_on_app and Stories.language?(conn.params["language"]) do
      conn
      |> put_resp_header("location", Env.archive_origin() <> conn.request_path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string))
      |> send_resp(301, "")
      |> halt()
    else
      conn
    end
  end

  defp alternates(translations) do
    Enum.map(translations, &%{language: &1.language, name: Languages.name(&1.language), dir: Languages.direction(&1.language), url: "#{Env.archive_origin()}/#{Archive.path_for(&1)}"})
  end

  defp for_card(row), do: row |> Map.put(:href, "/" <> Archive.path_for(row)) |> Map.put(:minutes, ReadingTime.from_length(row[:body_length]))

  def article(conn, %{"language" => language, "topic" => topic, "slug" => slug} = params) do
    if not Stories.language?(language), do: fail!(404, "Page not found.")
    story = Stories.find_editorial(%{language: language, slug: slug}) || fail!(404, "Article not found.")
    canonical = "#{Env.archive_origin()}/#{Archive.path_for(story)}"
    date = params["date"]

    on_canonical =
      date == Archive.date_of(story) and Regex.match?(@date, to_string(date)) and
        String.downcase(to_string(topic)) == String.downcase(to_string(story.category || "news"))

    if not on_canonical do
      # Permanent, as in the Node app: a story's canonical URL never changes, and
      # the undated form is what the old Hugo site published.
      conn |> put_resp_header("location", canonical) |> send_resp(301, "")
    else
      translations = Stories.translations_of(story.translation_key)
      related = Stories.related_to(%{language: language, category: story.category, exclude_id: story.id, limit: 3})

      more =
        if length(related) >= 3,
          do: related,
          else: related ++ Stories.also_in_language(%{language: language, exclude_ids: [story.id | Enum.map(related, & &1.id)], limit: 3 - length(related)})

      conn
      |> public_cache(600)
      |> page(title: story.headline, html_lang: language, dir: Languages.direction(language), body_class: "reading", indexable: true, canonical_url: canonical, alternates: alternates(translations))
      |> render(:article, story: story, date: Archive.date_of(story), minutes: ReadingTime.minutes(story.body), html: Markdown.render(story.body), related: Enum.map(more, &for_card/1), language: language, alternates: alternates(translations))
    end
  end

  def undated_article(conn, params), do: article(conn, params)

  def index(conn, %{"language" => language} = params) do
    # /sitemap-en.xml arrives here: one segment, and a route cannot say "prefix".
    case Regex.run(~r/^sitemap-([a-z]{2})\.xml$/, language) do
      [_, code] -> sitemap(conn, %{"language" => code})
      _ -> listing_index(conn, language, params)
    end
  end

  defp listing_index(conn, language, params) do
    if not Stories.language?(language), do: fail!(404, "Page not found.")
    page_no = page_number(params)
    items = Stories.list_editorial(%{language: language, limit: @page_size, offset: (page_no - 1) * @page_size})
    if items == [] and page_no > 1, do: fail!(404, "Page not found.")
    archive = Content.archive()

    listing(conn, language, %{heading: archive.title, intro: archive.intro, title: archive.title, category: nil, items: items, page: page_no})
  end

  def topic(conn, %{"language" => language, "topic" => name} = params) do
    if not Stories.language?(language), do: fail!(404, "Page not found.")
    page_no = page_number(params)
    items = Stories.list_editorial(%{language: language, category: name, limit: @page_size, offset: (page_no - 1) * @page_size})
    if items == [], do: fail!(404, "Nothing published in this section.")
    section = hd(items).category || name

    listing(conn, language, %{heading: section, intro: Content.fill(Content.archive().sectionIntro, %{section: section}), title: section, category: section, items: items, page: page_no})
  end

  defp listing(conn, language, opts) do
    conn
    |> public_cache(600)
    |> page(title: opts.title, html_lang: language, dir: Languages.direction(language), body_class: "reading", indexable: true)
    |> render(:index,
      heading: opts.heading,
      intro: opts.intro,
      language: language,
      category: opts.category,
      items: Enum.map(opts.items, &for_card/1),
      categories: Stories.editorial_categories(language),
      page: opts.page,
      more: length(opts.items) == @page_size
    )
  end

  defp page_number(params) do
    case Integer.parse(to_string(params["page"] || "1")) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  # ---- the archive host itself ----------------------------------------------------------

  def root(conn, _) do
    language = conn |> get_req_header("accept-language") |> List.first() |> preferred_language()
    conn |> put_resp_header("vary", "Accept-Language") |> no_store() |> redirect(to: "/#{language}")
  end

  def preferred_language(header, available \\ Stories.languages()) do
    (header || "")
    |> String.split(",")
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, index} ->
      [tag | params] = part |> String.trim() |> String.split(";")
      language = tag |> String.trim() |> String.downcase() |> String.split("-") |> List.first()

      q =
        Enum.find_value(params, 1.0, fn param ->
          case Regex.run(~r/^q=([\d.]+)$/, String.trim(param)) do
            [_, v] -> (case Float.parse(v), do: ({f, _} -> f; _ -> 1.0))
            _ -> nil
          end
        end)

      if language == "", do: [], else: [{language, q, index}]
    end)
    |> Enum.sort_by(fn {_, q, index} -> {-q, index} end)
    |> Enum.find_value("en", fn {language, _, _} -> if language in available, do: language end)
  end

  def robots(conn, _) do
    conn |> public_cache(3600) |> text("User-agent: *\nAllow: /\n\nSitemap: #{Env.archive_origin()}/sitemap.xml\n")
  end

  defp archive_map do
    rows = Stories.all_editorial()

    groups = Enum.group_by(rows, &(&1.translation_key || "#{&1.language}:#{&1.slug}"))

    newest =
      Enum.reduce(rows, %{}, fn row, acc ->
        Map.update(acc, row.language, row.date_slug, fn seen -> if row.date_slug > seen, do: row.date_slug, else: seen end)
      end)

    %{groups: groups, newest: newest}
  end

  def sitemap_index(conn, _) do
    %{newest: newest} = archive_map()

    sitemaps =
      Stories.languages()
      |> Enum.filter(&Map.has_key?(newest, &1))
      |> Enum.map(&%{loc: "#{Env.archive_origin()}/sitemap-#{&1}.xml", lastmod: newest[&1]})

    conn |> public_cache(3600) |> put_resp_content_type("application/xml") |> send_resp(200, Rnews1Web.Templates.sitemap_index(%{sitemaps: sitemaps}))
  end

  def sitemap(conn, %{"language" => language}) do
    if not Stories.language?(language), do: fail!(404, "Page not found.")
    %{groups: groups, newest: newest} = archive_map()
    if not Map.has_key?(newest, language), do: fail!(404, "Nothing published in this language.")
    origin = Env.archive_origin()

    urls =
      [%{loc: "#{origin}/#{language}", lastmod: newest[language], priority: "0.9"}] ++
        Enum.flat_map(groups, fn {_key, group} ->
          case Enum.find(group, &(&1.language == language)) do
            nil ->
              []

            row ->
              alternates = if length(group) > 1, do: Enum.map(group, &%{language: &1.language, url: "#{origin}/#{Archive.path_for(&1)}"}), else: []
              [%{loc: "#{origin}/#{Archive.path_for(row)}", lastmod: row.date_slug, priority: "0.7", alternates: alternates, x_default: Enum.find_value(alternates, &(&1.language == "en" && &1.url))}]
          end
        end)

    conn |> public_cache(3600) |> put_resp_content_type("application/xml") |> send_resp(200, Rnews1Web.Templates.sitemap(%{urls: urls}))
  end
end

defmodule Rnews1Web.ArchiveHTML do
  use Rnews1Web, :html
  embed_templates "archive_html/*"
end
