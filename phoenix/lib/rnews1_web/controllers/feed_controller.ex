defmodule Rnews1Web.FeedController do
  use Rnews1Web, :controller
  alias Rnews1.{BriefPage, Briefs, Companies, Content, Env, PDF, Stories, Subscribers}
  alias Rnews1.Util.{HTML, Hosts, Ids, Plans}
  alias Rnews1Web.Plugs.RateLimit

  plug RateLimit, :public_feed when action in [:rss, :embed, :article]
  plug :put_brand

  @feed_items 8

  defp put_brand(conn, _), do: conn |> assign(:brand, Content.brand()) |> assign(:app_origin, Env.app_origin())

  # On a tenant's own host the tenant is known from the Host header; on the
  # app host it comes from the token in the path. Both apply the publish gate.
  defp public_tenant(conn, params) do
    case conn.assigns[:site] do
      %{tenant: %{} = tenant, published: published} ->
        if not published, do: unpublished!()
        tenant

      _ ->
        token = params["token"] |> to_string() |> String.replace_suffix(".xml", "")
        if not Ids.uuid?(token), do: fail!(404, "Feed not found.")
        tenant = Companies.find_public_tenant(token) || fail!(404, "Feed not found.")
        if tenant.stakeholder_count < Subscribers.required_stakeholders(), do: unpublished!()
        tenant
    end
  end

  defp unpublished!, do: fail!(409, "This feed is not published yet. It goes live once the subscription is active and #{Subscribers.required_stakeholders()} addresses are on the newsletter list.")

  def present_story(tenant, story) do
    %{
      id: story.id,
      title: story.headline,
      summary: story.standfirst,
      body: story.body,
      source: story.source_name,
      published: story.published_at,
      source_url: HTML.safe_url(story.source_url),
      hosted_url: "#{Hosts.site_origin(tenant)}/news/#{story.id}"
    }
  end

  defp pub_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  defp pub_date(_), do: pub_date(DateTime.utc_now())

  # On a tenant's own host the publish gate is their coming-soon page.
  defp gated(conn, params, fun) do
    case conn.assigns[:site] do
      %{tenant: %{}, published: false} -> Rnews1Web.TenantSiteController.unpublished(conn)
      _ -> fun.(public_tenant(conn, params))
    end
  end

  def rss(conn, params), do: gated(conn, params, &rss_for(conn, &1))

  defp rss_for(conn, tenant) do
    origin = Hosts.site_origin(tenant)

    items =
      tenant.topic_key
      |> Stories.recent_for_topic(@feed_items)
      |> Enum.map(&Map.put(present_story(tenant, &1), :pub_date, pub_date(&1.published_at)))

    xml =
      Rnews1Web.Templates.rss(%{
        tenant: tenant,
        items: items,
        site_url: origin <> "/",
        feed_url: origin <> "/feed.xml",
        last_build_date: pub_date(tenant[:refreshed_at] || DateTime.utc_now())
      })

    conn |> public_cache(300) |> put_resp_content_type("application/rss+xml") |> send_resp(200, xml)
  end

  @embed_csp "default-src 'none'; style-src 'self'; img-src 'self' data:; script-src 'self'; connect-src 'self'; frame-ancestors *; base-uri 'none'; form-action 'none'"

  # The embed is the one route customers put in a frame on someone else's page,
  # so the frame policy is relaxed before the publishing gate rather than inside
  # it. A customer who pastes the snippet early — and the dashboard's own
  # preview — must see the coming-soon page in the frame; a refused frame leaves
  # a blank box with nothing in it to explain itself.
  def embed(conn, params) do
    conn = framable(conn)
    gated(conn, params, &embed_for(conn, &1))
  end

  defp framable(conn) do
    conn
    |> delete_resp_header("x-frame-options")
    |> put_resp_header("content-security-policy", @embed_csp)
  end

  defp embed_for(conn, tenant) do
    conn
    |> public_cache(300)
    |> page(title: "#{tenant.name} news", chrome: false, branding: Plans.entitlements(tenant).branding, html_lang: tenant.language)
    |> render(:embed, tenant: tenant, site_url: Hosts.site_origin(tenant) <> "/", items: tenant.topic_key |> Stories.recent_for_topic(@feed_items) |> Enum.map(&present_story(tenant, &1)))
  end

  def article(conn, params), do: gated(conn, params, &article_for(conn, params, &1))

  defp article_for(conn, params, tenant) do
    id = params["id"]
    if not Ids.uuid?(id), do: fail!(404, "Article not found.")
    story = Stories.find_by_id(id)
    # The story has to belong to this tenant's topic.
    if is_nil(story) or story.topic_key != tenant.topic_key, do: fail!(404, "Article not found.")
    item = present_story(tenant, story)

    # The story's own standfirst describes the page to a search engine; the
    # layout falls back to its usual description when the story has none.
    conn
    |> public_cache(300)
    |> page(title: story.headline, indexable: true, canonical_url: item.hosted_url, html_lang: tenant.language, meta_description: story.standfirst)
    |> render(:article, tenant: tenant, item: item, site_url: Hosts.site_origin(tenant) <> "/")
  end

  # ---- briefs -------------------------------------------------------------------------

  defp require_brief(conn, id) do
    if not Ids.uuid?(id), do: fail!(404, "Issue not found.")
    record = Briefs.find_unexpired(id) || fail!(404, "Issue not found.")

    case conn.assigns[:site] do
      %{tenant: %{id: tenant_id}} when record.tenant_id != tenant_id -> fail!(404, "Issue not found.")
      _ -> record
    end
  end

  def brief(conn, %{"id" => id}) do
    record = require_brief(conn, id)
    %{html: html} = BriefPage.render(record, tracker: Rnews1Web.Analytics.tag(conn.assigns))
    conn |> no_store() |> html(html)
  end

  def brief_email(conn, %{"id" => id}) do
    record = require_brief(conn, id)
    conn |> no_store() |> html(record.html || "")
  end

  @doc "Made on first request if the worker has not already, so a hand-built report prints too."
  def pdf(conn, %{"id" => id}) do
    record = require_brief(conn, id)
    file = PDF.brief_pdf_path(record.id)

    if not record.has_pdf or not File.exists?(file) do
      if not PDF.available?(), do: fail!(503, "PDF rendering is unavailable on this server.")
      %{html: html, content: content} = BriefPage.render(record)
      PDF.write_brief_pdf(record.id, html, content.print)
      Briefs.mark_pdf_written(record.id)
    end

    conn |> no_store() |> send_download({:file, file}, filename: "newsletter-#{record.date_slug || record.id}.pdf", content_type: "application/pdf")
  end
end

defmodule Rnews1Web.FeedHTML do
  use Rnews1Web, :html
  embed_templates "feed_html/*"
end
