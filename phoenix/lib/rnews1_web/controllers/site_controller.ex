defmodule Rnews1Web.SiteController do
  use Rnews1Web, :controller
  alias Rnews1.{Content, DB, Env, PayPal, Stories}
  alias Rnews1.Util.Hosts

  plug :put_brand

  defp put_brand(conn, _), do: conn |> assign(:brand, Content.brand()) |> assign(:app_origin, Env.app_origin()) |> assign(:support_email, Env.support_email())

  # The sales pitch belongs to this page alone. content.json's brand description
  # is the fallback for every www news page too, where a reader came for the news
  # rather than for a product, so the home page carries its own description.
  @home_description "Automated industry newsletter for search and email traffic: RNews1 writes daily stories on your topics, emails your list and gives each an indexable page."

  def home(conn, _params) do
    conn
    |> page(
      title: "Automated industry newsletter for search and email traffic",
      indexable: true,
      meta_description: @home_description
    )
    |> render(:home)
  end

  def dashboard(conn, params) do
    conn = Rnews1Web.Plugs.Auth.require_auth_page(conn, [])
    # body_class "app" widens the shell past the 56rem reading measure and turns
    # on the sidebar grid: this is a console, not an article.
    if conn.halted,
      do: conn,
      else: conn |> no_store() |> page(title: "Dashboard", body_class: "app") |> render(:dashboard, checkout: params["checkout"])
  end

  @doc "Sign in and register are the same page because they are the same act."
  def signin(conn, _params) do
    if conn.assigns[:signed_in] do
      redirect(conn, to: "/app")
    else
      register = conn.request_path == "/register"

      conn
      |> no_store()
      |> page(title: if(register, do: "Create your account", else: "Sign in"), indexable: true)
      |> render(:signin, heading: if(register, do: "Create your RNews1 account", else: "Sign in to RNews1"))
    end
  end

  def privacy(conn, _), do: conn |> page(title: "Privacy", indexable: true) |> render(:privacy)
  def terms(conn, _), do: conn |> page(title: "Terms", indexable: true) |> render(:terms)

  def health(conn, _) do
    DB.value("SELECT 1")
    conn |> no_store() |> json(%{ok: true, database: true, payments_configured: PayPal.configured?()})
  end

  def robots(conn, _) do
    lines = [
      "User-agent: *",
      "",
      "# Hosted stories, the news archive, and public feeds.",
      "Allow: /news/",
      "Allow: /feed/",
      "",
      "# Private, tokenised, or belonging in someone else's page.",
      "Disallow: /app",
      "Disallow: /admin",
      "Disallow: /api/",
      "Disallow: /embed/",
      "Disallow: /brief/",
      "Disallow: /pdf/",
      "Disallow: /login/",
      "Disallow: /confirm/",
      "Disallow: /u/",
      "Disallow: /a/",
      "",
      "Sitemap: #{Env.app_origin()}/sitemap.xml"
    ]

    conn |> public_cache(3600) |> text(Enum.join(lines, "\n") <> "\n")
  end

  def sitemap(conn, _) do
    app = Env.app_origin()

    urls =
      [
        %{loc: app, priority: "1.0"},
        %{loc: "#{app}/privacy", priority: "0.3"},
        %{loc: "#{app}/terms", priority: "0.3"},
        %{loc: "#{app}/login", priority: "0.5"}
      ] ++
        if Hosts.archive_label() == nil and Env.archive_host() == Env.app_host(),
          do: Enum.map(Stories.languages(), &%{loc: "#{Env.archive_origin()}/#{&1}", priority: "0.9"}),
          else: []

    conn
    |> public_cache(3600)
    |> put_resp_content_type("application/xml")
    |> send_resp(200, Rnews1Web.Templates.sitemap(%{urls: urls}))
  end
end

defmodule Rnews1Web.SiteHTML do
  use Rnews1Web, :html
  embed_templates "site_html/*"
end
