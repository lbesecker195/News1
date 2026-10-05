defmodule Rnews1Web.TenantSiteController do
  @moduledoc "A tenant's own site: their stories, their name on the page, a feed and an embed at fixed paths."
  use Rnews1Web, :controller
  alias Rnews1.{Content, Env, Stories, Subscribers}
  alias Rnews1Web.FeedController

  @stories_on_index 20
  @stories_in_sitemap 200

  plug :put_brand
  plug :known_tenant when action not in [:unknown]

  defp put_brand(conn, _), do: conn |> assign(:brand, Content.brand()) |> assign(:app_origin, Env.app_origin())

  defp known_tenant(conn, _) do
    case conn.assigns[:site] do
      %{tenant: %{}} -> conn
      _ -> conn |> unknown(%{}) |> halt()
    end
  end

  def index(conn, _) do
    %{tenant: tenant, origin: origin, published: published} = conn.assigns.site

    if not published do
      unpublished(conn)
    else
      items = tenant.topic_key |> Stories.recent_for_topic(@stories_on_index) |> Enum.map(&FeedController.present_story(tenant, &1))
      keywords = List.wrap(tenant.keywords)
      label = Rnews1Web.Templates.news_label(tenant.industry)

      conn
      |> public_cache(300)
      |> page(title: home_title(tenant, label), indexable: true, canonical_url: origin <> "/", html_lang: tenant.language, meta_description: home_description(tenant, label))
      |> render(:index,
        tenant: tenant,
        items: items,
        news_label: label,
        following: [tenant.industry | keywords] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · "),
        feed_url: origin <> "/feed.xml"
      )
    end
  end

  # The hosted home is written for someone arriving from a search, so its title
  # and description name the subject ("Acme: Robotics news") rather than the
  # product that writes it. Every part is optional in the row, and each one
  # that is missing simply drops out of the sentence. `label` is the industry's
  # news label ("Robotics news", or plain "news" without an industry).
  defp home_title(tenant, label) do
    case present(tenant.name) do
      nil -> "Daily #{label}"
      name when label == "news" -> "#{name} news"
      name -> "#{name}: #{label}"
    end
  end

  defp home_description(tenant, label) do
    name = present(tenant.name)
    keywords = tenant.keywords |> List.wrap() |> Enum.map(&present/1) |> Enum.reject(&is_nil/1)

    subject = "Daily #{label}"
    selected = if name, do: " selected for #{name}", else: ""
    following = if keywords != [], do: ", following #{join_and(keywords)}", else: ""

    "#{subject}#{selected}#{following}. Written from published reporting, with every source named."
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  defp join_and([only]), do: only
  defp join_and(list), do: Enum.join(Enum.drop(list, -1), ", ") <> " and " <> List.last(list)

  def unpublished(conn) do
    tenant = conn.assigns.site.tenant

    conn
    |> put_view(html: Rnews1Web.TenantSiteHTML)
    |> put_status(409)
    |> no_store()
    |> page(title: "#{tenant.name || "This site"} — coming soon")
    |> render(:unpublished, tenant: tenant, required: Subscribers.required_stakeholders())
  end

  def unknown(conn, _) do
    conn |> put_status(404) |> no_store() |> page(title: "No site here") |> render(:unknown, host: conn.assigns.site.host)
  end

  def robots(conn, _) do
    %{origin: origin, published: published} = conn.assigns.site

    lines =
      if published,
        do: ["User-agent: *", "Allow: /", "Disallow: /embed", "Disallow: /brief/", "Disallow: /pdf/", "", "Sitemap: #{origin}/sitemap.xml"],
        else: ["User-agent: *", "Disallow: /"]

    conn |> public_cache(3600) |> text(Enum.join(lines, "\n") <> "\n")
  end

  def sitemap(conn, _) do
    %{tenant: tenant, origin: origin, published: published} = conn.assigns.site
    if not published, do: fail!(404, "Not published.")
    items = Stories.recent_for_topic(tenant.topic_key, @stories_in_sitemap)
    dates = items |> Enum.map(& &1.published_at) |> Enum.reject(&is_nil/1) |> Enum.map(&(&1 |> DateTime.to_date() |> Date.to_iso8601()))

    urls =
      [%{loc: origin <> "/", lastmod: if(dates != [], do: Enum.max(dates)), priority: "1.0"}] ++
        Enum.map(items, &%{loc: "#{origin}/news/#{&1.id}", lastmod: &1.published_at && &1.published_at |> DateTime.to_date() |> Date.to_iso8601(), priority: "0.8"})

    conn |> public_cache(3600) |> put_resp_content_type("application/xml") |> send_resp(200, Rnews1Web.Templates.sitemap(%{urls: urls}))
  end

  # Token URLs from before the site existed, by redirect, only with this tenant's own token.
  def legacy_feed(conn, %{"token" => token}), do: legacy(conn, String.replace_suffix(token, ".xml", ""), "/feed.xml")
  def legacy_embed(conn, %{"token" => token}), do: legacy(conn, token, "/embed")
  def legacy_article(conn, %{"token" => token, "id" => id}), do: legacy(conn, token, "/news/#{URI.encode(id)}")

  defp legacy(conn, token, target) do
    if token == conn.assigns.site.tenant.public_token, do: redirect(conn, to: target), else: fail!(404, "Not found.")
  end
end

defmodule Rnews1Web.TenantSiteHTML do
  use Rnews1Web, :html
  embed_templates "tenant_site_html/*"
end
