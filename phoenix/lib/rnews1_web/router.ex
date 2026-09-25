defmodule Rnews1Web.Router do
  @moduledoc "The app host: marketing, dashboard, API, admin, webhooks, token URLs."
  use Rnews1Web, :router
  import Rnews1Web.Plugs.Auth
  import Rnews1Web.Plugs.Origin
  alias Rnews1Web.Plugs.RateLimit

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {Rnews1Web.Layouts, :root}
    plug :attach_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug RateLimit, :api
    plug :protect_mutations
  end

  pipeline :authed_api do
    plug :require_auth
  end

  pipeline :webhook do
    plug :accepts, ["json"]
  end

  pipeline :admin_auth do
    plug :require_admin
  end

  scope "/webhooks", Rnews1Web do
    pipe_through :webhook
    post "/paypal", WebhookController, :paypal
    post "/mailgun", WebhookController, :mailgun
  end

  # Click tracking, on every host.
  scope "/", Rnews1Web do
    post "/e", EventController, :collect
  end

  scope "/api", Rnews1Web do
    pipe_through :api

    post "/login", AuthController, :request_login
    post "/login/password", AuthController, :password_login

    scope "/" do
      pipe_through :authed_api

      post "/logout", AuthController, :logout
      post "/password", AuthController, :set_password
      delete "/password", AuthController, :remove_password

      get "/me", CompanyController, :me
      post "/company", CompanyController, :save
      post "/suggest", CompanyController, :suggest
      get "/preview", CompanyController, :preview

      post "/subscribers", SubscriberController, :add
      delete "/subscribers", SubscriberController, :remove

      post "/site/subdomain", DomainController, :rename_subdomain
      post "/site/domain", DomainController, :set_domain
      post "/site/domain/verify", DomainController, :verify_domain
      delete "/site/domain", DomainController, :remove_domain

      post "/checkout", BillingController, :checkout
      post "/cancel", BillingController, :cancel
    end
  end

  scope "/admin", Rnews1Web do
    pipe_through :browser

    get "/login", AdminController, :show_login
    post "/login", AdminController, :login

    scope "/" do
      pipe_through :admin_auth

      get "/", AdminController, :dashboard
      post "/logout", AdminController, :logout
      post "/advertisers", AdminController, :create_advertiser
      post "/campaigns", AdminController, :create_campaign
      post "/creatives", AdminController, :create_creative
      post "/campaigns/:id/status", AdminController, :set_campaign_status
    end
  end

  scope "/", Rnews1Web do
    pipe_through :browser

    get "/", SiteController, :home
    get "/app", SiteController, :dashboard
    get "/login", SiteController, :signin
    get "/register", SiteController, :signin
    get "/robots.txt", SiteController, :robots
    get "/sitemap.xml", SiteController, :sitemap
    get "/privacy", SiteController, :privacy
    get "/terms", SiteController, :terms
    get "/health", SiteController, :health
    get "/.well-known/tls-ask", DomainController, :tls_ask

    get "/login/:token", AuthController, :show_login
    post "/login/:token", AuthController, :complete_login

    get "/confirm/:token", SubscriberController, :show_confirmation
    post "/confirm/:token", SubscriberController, :confirm
    get "/u/:token", SubscriberController, :show_unsubscribe
    # No origin guard: supports Mailgun / mail-client one-click POST.
    post "/u/:token", SubscriberController, :unsubscribe

    get "/feed/:token", FeedController, :rss
    get "/embed/:token", FeedController, :embed
    get "/news/:token/:id", FeedController, :article

    get "/a/p/:id", AdController, :pixel
    get "/a/c/:id", AdController, :click

    get "/brief/:id", FeedController, :brief
    get "/brief/:id/email", FeedController, :brief_email
    get "/pdf/:id", FeedController, :pdf

    # The archive's paths still resolve here, but 301 to www.
    get "/:language/:topic/:slug/:date", ArchiveController, :article
    get "/:language/:topic/:slug", ArchiveController, :undated_article
    get "/:language/:topic", ArchiveController, :topic
    get "/:language", ArchiveController, :index
  end

  scope "/", Rnews1Web do
    pipe_through :browser
    match :*, "/*path", NotFoundController, :not_found
  end
end

defmodule Rnews1Web.ArchiveRouter do
  @moduledoc "www — the editorial archive, every section in every language."
  use Rnews1Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {Rnews1Web.Layouts, :root}
  end

  scope "/", Rnews1Web do
    post "/e", EventController, :collect
  end

  scope "/", Rnews1Web do
    pipe_through :browser

    get "/", ArchiveController, :root
    get "/robots.txt", ArchiveController, :robots
    get "/sitemap.xml", ArchiveController, :sitemap_index
    # /sitemap-{lang}.xml is a single segment with a literal prefix, which a
    # Phoenix route cannot express; ArchiveController.index recognises it.
    get "/:language/:topic/:slug/:date", ArchiveController, :article
    get "/:language/:topic/:slug", ArchiveController, :undated_article
    get "/:language/:topic", ArchiveController, :topic
    get "/:language", ArchiveController, :index
  end

  scope "/", Rnews1Web do
    pipe_through :browser
    match :*, "/*path", NotFoundController, :not_found
  end
end

defmodule Rnews1Web.SiteRouter do
  @moduledoc "A customer's host: their stories, feed, embed, briefs — and nothing of the app."
  use Rnews1Web, :router
  alias Rnews1Web.Plugs.RateLimit

  pipeline :browser do
    plug :accepts, ["html", "xml"]
    plug :put_root_layout, html: {Rnews1Web.Layouts, :root}
  end

  pipeline :public_feed do
    plug RateLimit, :public_feed
  end

  scope "/", Rnews1Web do
    post "/e", EventController, :collect
  end

  scope "/", Rnews1Web do
    pipe_through :browser

    get "/", TenantSiteController, :index
    get "/robots.txt", TenantSiteController, :robots
    get "/sitemap.xml", TenantSiteController, :sitemap

    scope "/" do
      pipe_through :public_feed
      get "/feed.xml", FeedController, :rss
      get "/embed", FeedController, :embed
      get "/news/:id", FeedController, :article
    end

    get "/brief/:id", FeedController, :brief
    get "/brief/:id/email", FeedController, :brief_email
    get "/pdf/:id", FeedController, :pdf

    get "/feed/:token", TenantSiteController, :legacy_feed
    get "/embed/:token", TenantSiteController, :legacy_embed
    get "/news/:token/:id", TenantSiteController, :legacy_article
  end

  scope "/", Rnews1Web do
    pipe_through :browser
    match :*, "/*path", NotFoundController, :not_found
  end
end
