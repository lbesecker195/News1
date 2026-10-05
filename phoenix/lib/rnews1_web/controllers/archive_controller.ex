defmodule Rnews1Web.ArchiveController do
  @moduledoc """
  An editorial site. There is more than one now: the archive is the default
  publication, and every additional news site on its own domain is another. The
  publication comes from the host the request arrived on, and everything that
  used to be read from ARCHIVE_ORIGIN — the origin in canonical and hreflang
  URLs, which sections exist, which languages are published — is read from it.
  """
  use Rnews1Web, :controller
  alias Rnews1.{Content, Env, Publications, Stories}
  alias Rnews1.Util.{Hosts, Languages, Markdown, ReadingTime}
  alias Rnews1Web.Archive

  @page_size 24
  @date ~r/^\d{4}-\d{2}-\d{2}$/

  plug :put_brand
  plug :put_publication
  plug :archive_redirect when action in [:article, :undated_article, :topic, :index]
  plug :same_origin when action in [:subscribe]

  defp put_brand(conn, _), do: conn |> assign(:brand, Content.brand()) |> assign(:app_origin, Env.app_origin())

  # The host plug assigns the publication for an archive host. The app host
  # reaches these actions too, on its way to a 301, and has none — it stands in
  # for the default one so the redirect below has an origin to aim at.
  defp put_publication(conn, _) do
    publication = conn.assigns[:publication] || Publications.default() || Publications.ensure_default()

    conn
    |> assign(:publication, publication)
    |> assign(:publication_origin, Hosts.publication_origin(publication))
  end

  # On the app host the archive paths 301 to the publication — unless it shares the host.
  defp archive_redirect(conn, _) do
    archive_on_app = Env.archive_host() == Env.app_host()

    if conn.assigns[:host_kind] != :archive and not archive_on_app and Stories.language?(conn.params["language"]) do
      conn
      |> put_resp_header("location", conn.assigns.publication_origin <> conn.request_path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string))
      |> send_resp(301, "")
      |> halt()
    else
      conn
    end
  end

  # A language this publication does not run is a 404 here even when another
  # publication runs it, so one site's locales never leak into another's URLs.
  defp publishes?(conn, language), do: Stories.language?(language) and language in List.wrap(conn.assigns.publication.languages)

  defp alternates(origin, translations) do
    Enum.map(translations, &%{language: &1.language, name: Languages.name(&1.language), dir: Languages.direction(&1.language), url: "#{origin}/#{Archive.path_for(&1)}"})
  end

  defp for_card(row), do: row |> Map.put(:href, "/" <> Archive.path_for(row)) |> Map.put(:minutes, ReadingTime.from_length(row[:body_length]))

  def article(conn, %{"language" => language, "topic" => topic, "slug" => slug} = params) do
    if not publishes?(conn, language), do: fail!(404, "Page not found.")
    publication = conn.assigns.publication

    story =
      Stories.find_editorial(%{publication_id: publication.id, language: language, slug: slug}) ||
        fail!(404, "Article not found.")

    canonical = "#{conn.assigns.publication_origin}/#{Archive.path_for(story)}"
    date = params["date"]

    on_canonical =
      date == Archive.date_of(story) and Regex.match?(@date, to_string(date)) and
        String.downcase(to_string(topic)) == String.downcase(to_string(story.category || "news"))

    if not on_canonical do
      # Permanent, as in the Node app: a story's canonical URL never changes, and
      # the undated form is what the old Hugo site published.
      conn |> put_resp_header("location", canonical) |> send_resp(301, "")
    else
      translations = Stories.translations_of(publication.id, story.translation_key)
      related =
        Stories.related_to(%{
          publication_id: publication.id,
          language: language,
          category: story.category,
          exclude_id: story.id,
          limit: 3
        })

      more =
        if length(related) >= 3,
          do: related,
          else:
            related ++
              Stories.also_in_language(%{
                publication_id: publication.id,
                language: language,
                exclude_ids: [story.id | Enum.map(related, & &1.id)],
                limit: 3 - length(related)
              })

      conn
      |> public_cache(600)
      |> page(title: story.headline, html_lang: language, dir: Languages.direction(language), body_class: "reading", indexable: true, canonical_url: canonical, alternates: alternates(conn.assigns.publication_origin, translations), meta_description: story.standfirst)
      |> render(:article, story: story, date: Archive.date_of(story), minutes: ReadingTime.minutes(story.body), html: Markdown.render(story.body), related: Enum.map(more, &for_card/1), language: language, alternates: alternates(conn.assigns.publication_origin, translations))
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
    if not publishes?(conn, language), do: fail!(404, "Page not found.")
    page_no = page_number(params)

    items =
      Stories.list_editorial(%{
        publication_id: conn.assigns.publication.id,
        language: language,
        limit: @page_size,
        offset: (page_no - 1) * @page_size
      })

    if items == [] and page_no > 1, do: fail!(404, "Page not found.")
    archive = Content.archive()
    publication = conn.assigns.publication

    # content.json's copy is about the briefing product — "written for one
    # reader at a time". True of the archive, and nothing to do with a fashion
    # title, so another publication speaks for itself or says nothing.
    {title, intro} =
      if own_masthead?(conn),
        do: {publication.name, publication.tagline},
        else: {archive.title, archive.intro}

    listing(conn, language, %{heading: title, intro: intro, title: title, category: nil, items: items, page: page_no})
  end

  defp own_masthead?(conn), do: conn.assigns.publication.slug != Publications.default_slug()

  def topic(conn, %{"language" => language, "topic" => name} = params) do
    if not publishes?(conn, language), do: fail!(404, "Page not found.")
    page_no = page_number(params)

    items =
      Stories.list_editorial(%{
        publication_id: conn.assigns.publication.id,
        language: language,
        category: name,
        limit: @page_size,
        offset: (page_no - 1) * @page_size
      })

    if items == [], do: fail!(404, "Nothing published in this section.")
    section = hd(items).category || name
    intro = if own_masthead?(conn), do: nil, else: Content.fill(Content.archive().sectionIntro, %{section: section})

    listing(conn, language, %{heading: section, intro: intro, title: section, category: section, items: items, page: page_no})
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
      categories: Stories.editorial_categories(conn.assigns.publication.id, language),
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
    # Negotiated against what this publication runs, not against all twelve:
    # an English-only site must land an Arabic reader on English, not on a 404.
    available = List.wrap(conn.assigns.publication.languages)
    language = conn |> get_req_header("accept-language") |> List.first() |> preferred_language(available)

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
    |> Enum.find_value(fallback_language(available), fn {language, _, _} -> if language in available, do: language end)
  end

  # English when the publication runs it, otherwise whatever it does run: a
  # site with no English has to send an unmatched reader somewhere real.
  defp fallback_language(available), do: if("en" in available, do: "en", else: List.first(available) || "en")

  # The app's CSRF defence, on a publication's own host: a state-changing request
  # must come from a page that host served. Browsers always send Origin on a
  # cross-site POST, so an exact match is enough without a token round trip.
  defp same_origin(conn, _) do
    if get_req_header(conn, "origin") == [conn.assigns.publication_origin] do
      conn
    else
      conn |> send_resp(403, "Invalid request origin.") |> halt()
    end
  end

  @doc """
  Subscribes the address to this publication's daily edition, at once: every
  address entered is taken as opted in, so there is no confirmation email.

  Says the same thing whatever happened — new, already subscribed, or an address
  that has opted out — so the form cannot be used to learn any of those things.
  Only an address that is not one is told so.
  """
  def subscribe(conn, params) do
    publication = conn.assigns.publication

    case Rnews1.Newsletter.subscribe(publication, params["email"]) do
      :ok ->
        newsletter_page(conn, "You're subscribed",
          "The #{publication.name} newsletter arrives each morning: the day's stories, and the highlight of the week. Every email has a one-click unsubscribe link.")

      {:error, :invalid_email} ->
        conn
        |> put_status(400)
        |> newsletter_page("That doesn't look like an email address", "Go back and check it, then try again.")
    end
  end

  defp newsletter_page(conn, heading, message) do
    conn
    |> no_store()
    |> page(title: heading, indexable: false)
    |> render(:newsletter_message, heading: heading, message: message)
  end

  @doc """
  The publication's latest newsletter edition, as the web version every emailed
  copy links to from "View in a browser". Same template on every publication;
  the host decides which one.

  Kept out of search: it repeats the day's story openings under a URL whose
  contents change every morning, and the stories themselves are what should rank.
  """
  def newsletter(conn, _) do
    case Rnews1.Editions.build(conn.assigns.publication) do
      nil ->
        fail!(404, "No edition has been published here yet.")

      edition ->
        conn
        |> public_cache(600)
        |> put_resp_header("x-robots-tag", "noindex")
        |> put_resp_content_type("text/html")
        |> send_resp(200, Rnews1.EditionMail.render_html(edition))
    end
  end

  def robots(conn, _) do
    conn |> public_cache(3600) |> text("User-agent: *\nAllow: /\n\nSitemap: #{conn.assigns.publication_origin}/sitemap.xml\n")
  end

  defp archive_map(publication_id) do
    rows = Stories.all_editorial(publication_id)

    groups = Enum.group_by(rows, &(&1.translation_key || "#{&1.language}:#{&1.slug}"))

    newest =
      Enum.reduce(rows, %{}, fn row, acc ->
        Map.update(acc, row.language, row.date_slug, fn seen -> if row.date_slug > seen, do: row.date_slug, else: seen end)
      end)

    %{groups: groups, newest: newest}
  end

  def sitemap_index(conn, _) do
    %{newest: newest} = archive_map(conn.assigns.publication.id)
    origin = conn.assigns.publication_origin

    sitemaps =
      conn.assigns.publication.languages
      |> List.wrap()
      |> Enum.filter(&Map.has_key?(newest, &1))
      |> Enum.map(&%{loc: "#{origin}/sitemap-#{&1}.xml", lastmod: newest[&1]})

    conn |> public_cache(3600) |> put_resp_content_type("application/xml") |> send_resp(200, Rnews1Web.Templates.sitemap_index(%{sitemaps: sitemaps}))
  end

  def sitemap(conn, %{"language" => language}) do
    if not publishes?(conn, language), do: fail!(404, "Page not found.")
    %{groups: groups, newest: newest} = archive_map(conn.assigns.publication.id)
    if not Map.has_key?(newest, language), do: fail!(404, "Nothing published in this language.")
    origin = conn.assigns.publication_origin

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
