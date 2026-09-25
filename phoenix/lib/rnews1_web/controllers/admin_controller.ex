defmodule Rnews1Web.AdminController do
  use Rnews1Web, :controller
  alias Rnews1.{Admins, Ads, Content, Env}
  alias Rnews1.Util.Ids
  alias Rnews1Web.Plugs.{Auth, RateLimit}
  import Rnews1Web.Validation

  plug :no_cache_no_index
  plug :put_brand
  plug RateLimit, :admin_login when action in [:login]
  plug :same_origin when action in [:login, :logout, :create_advertiser, :create_campaign, :create_creative, :set_campaign_status]

  defp no_cache_no_index(conn, _), do: conn |> no_store() |> put_resp_header("x-robots-tag", "noindex, nofollow")
  defp put_brand(conn, _), do: conn |> assign(:brand, Content.brand()) |> assign(:app_origin, Env.app_origin())
  defp same_origin(conn, _), do: Rnews1Web.Plugs.Origin.require_same_origin(conn, [])

  defp cookie, do: cookie_opts(path: "/admin")

  def show_login(conn, _), do: conn |> page(title: "Staff sign in") |> render(:login, error: nil)

  def login(conn, params) do
    email = (params["email"] || "") |> to_string() |> String.trim() |> String.downcase()
    password = to_string(params["password"] || "")

    case Admins.authenticate(email, password) do
      nil ->
        conn |> put_status(401) |> page(title: "Staff sign in") |> render(:login, error: "Those details were not recognised.")

      admin ->
        secret = Ids.token()
        Admins.create_session(Ids.hash(secret), admin.id)
        conn |> put_resp_cookie(Auth.admin_cookie(), secret, Keyword.put(cookie(), :max_age, 12 * 3600)) |> redirect(to: "/admin")
    end
  end

  def logout(conn, _) do
    case fetch_cookies(conn).req_cookies[Auth.admin_cookie()] do
      value when is_binary(value) -> Admins.delete_session(Ids.hash(value))
      _ -> :ok
    end

    conn |> delete_resp_cookie(Auth.admin_cookie(), cookie()) |> redirect(to: "/admin/login")
  end

  def dashboard(conn, params) do
    conn
    |> page(title: "Ad server")
    |> render(:dashboard, admin: conn.assigns.admin, campaigns: Ads.campaign_report(), advertisers: Ads.list_advertisers(), platform: Ads.platform_totals(), notice: params["ok"])
  end

  def create_advertiser(conn, params) do
    name = string!(params["name"], min: 1, max: 120)
    contact_email = if params["contact_email"] in [nil, ""], do: nil, else: email!(params["contact_email"])
    Ads.create_advertiser(name, contact_email)
    redirect(conn, to: "/admin?ok=Advertiser+added")
  end

  defp list(value), do: value |> to_string() |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.take(25)

  def create_campaign(conn, params) do
    input = %{
      advertiser_id: uuid!(params["advertiser_id"]),
      name: string!(params["name"], min: 1, max: 120),
      starts_on: date!(params["starts_on"]),
      ends_on: date!(params["ends_on"]),
      cpm_cents: int!(params["cpm_cents"] || 0, 0, 1_000_000),
      daily_cap: int!(params["daily_cap"] || 0, 0, 1_000_000_000),
      total_cap: int!(params["total_cap"] || 0, 0, 1_000_000_000)
    }

    if Date.compare(input.ends_on, input.starts_on) == :lt, do: fail!(400, "A campaign cannot end before it starts.")
    Ads.create_campaign(input, %{titles: list(params["titles"]), industries: list(params["industries"]), topics: list(params["topics"])})
    redirect(conn, to: "/admin?ok=Campaign+created+as+a+draft")
  end

  def create_creative(conn, params) do
    slot = params["slot"]
    if slot not in ["sponsored_story", "banner"], do: fail!(400, "Invalid input.")
    click_url = string!(params["click_url"], min: 1, max: 2000)
    if not Regex.match?(~r/^https?:\/\//i, click_url), do: fail!(400, "A click URL must start with http:// or https://")

    Ads.create_creative(%{
      campaign_id: uuid!(params["campaign_id"]),
      slot: slot,
      headline: string!(params["headline"], min: 1, max: 200),
      body: string!(params["body"], min: 1, max: 600),
      cta: if(params["cta"] in [nil, ""], do: nil, else: string!(params["cta"], max: 60)),
      click_url: click_url
    })

    redirect(conn, to: "/admin?ok=Creative+added")
  end

  @statuses ~w(draft active paused completed)

  def set_campaign_status(conn, %{"id" => id} = params) do
    status = to_string(params["status"] || "")
    if status not in @statuses, do: fail!(400, "Unknown campaign status.")
    Ads.set_campaign_status(uuid!(id), status)
    redirect(conn, to: "/admin?ok=Campaign+#{status}")
  end
end

defmodule Rnews1Web.AdminHTML do
  use Rnews1Web, :html
  embed_templates "admin_html/*"
end
