defmodule Rnews1Web.BillingController do
  use Rnews1Web, :controller
  alias Rnews1.Billing
  alias Rnews1.Util.Plans

  defp refuse_if_comped!(tenant) do
    if Plans.comped?(tenant), do: fail!(409, "This account is not billed. There is no subscription to change.")
  end

  def checkout(conn, _) do
    refuse_if_comped!(conn.assigns.tenant)
    json(conn, %{url: Billing.create_checkout(conn.assigns.tenant.id)})
  end

  def cancel(conn, _) do
    refuse_if_comped!(conn.assigns.tenant)
    json(conn, Billing.cancel_renewal(conn.assigns.tenant.id))
  end
end

defmodule Rnews1Web.DomainController do
  use Rnews1Web, :controller
  alias Rnews1.{Domains, Env, Sites}
  alias Rnews1.Util.{Hosts, Plans}

  def site_summary(tenant) do
    full = Sites.find_site_by_id(tenant.id)
    domain = Sites.custom_domain_for(tenant.id)
    next_at = Sites.next_rename_at(full)

    %{
      origin: Hosts.site_origin(full),
      subdomain: full.subdomain,
      entitlements: Plans.entitlements(full),
      sitesDomain: Env.sites_domain(),
      platformHost: Hosts.platform_host(full.subdomain),
      platformOrigin: Hosts.site_origin(%{subdomain: full.subdomain}),
      rename: %{
        allowed: is_nil(next_at),
        nextAt: next_at && DateTime.to_iso8601(next_at),
        intervalHours: Sites.rename_interval_hours(),
        redirectDays: Sites.history_days()
      },
      domain: domain && present_domain(domain, full)
    }
  end

  defp present_domain(domain, tenant) do
    %{
      hostname: domain.hostname,
      verified: not is_nil(domain.verified_at),
      verifiedAt: domain.verified_at,
      lastCheckedAt: domain.last_checked_at,
      lastError: domain.last_error,
      records: Domains.dns_records(domain, tenant)
    }
  end

  def rename_subdomain(conn, _) do
    subdomain = (body(conn)["subdomain"] || "") |> to_string() |> String.trim() |> String.downcase()
    if String.length(subdomain) > 80, do: fail!(400, "Invalid input.")
    if error = Hosts.label_error(subdomain), do: fail!(400, error)

    case Sites.rename(conn.assigns.tenant.id, subdomain) do
      {:ok, label} ->
        json(conn, %{
          message: "Your site is now #{Hosts.site_origin(%{subdomain: label})}. The old address redirects for #{Sites.history_days()} days.",
          site: site_summary(conn.assigns.tenant)
        })

      {:error, :same} ->
        fail!(400, "That is already your subdomain.")

      {:error, :taken} ->
        # "Taken" is unhelpful when the thing holding it is one of your own news
        # sites: the owner reads it as a stranger having got there first and has
        # no way to find out otherwise.
        if Sites.publication_label?(subdomain) do
          fail!(409, "#{Hosts.platform_host(subdomain)} is already one of your news sites. A newsletter and a news site cannot share an address.")
        else
          fail!(409, "That subdomain is taken.")
        end

      {:error, {:throttled, next_at}} ->
        wait = max(1, DateTime.diff(next_at, DateTime.utc_now(), :second))

        conn
        |> put_resp_header("retry-after", to_string(wait))
        |> put_status(429)
        |> json(%{
          error:
            "You can rename once every #{Sites.rename_interval_hours()} hours. Next rename available #{next_at |> DateTime.to_iso8601() |> String.replace("T", " ") |> String.slice(0, 16)} UTC."
        })

      _ ->
        fail!(400, "That subdomain cannot be used.")
    end
  end

  def set_domain(conn, _) do
    tenant = conn.assigns.tenant

    if not Plans.enterprise?(tenant) do
      fail!(403, "A custom domain is part of the enterprise plan. Your site is live at #{Hosts.site_origin(Sites.find_site_by_id(tenant.id))} — contact #{Env.support_email()} to move it to a hostname you own.")
    end

    hostname = Hosts.normalise_hostname((body(conn)["hostname"] || "") |> to_string() |> String.slice(0, 300))
    if error = Hosts.hostname_error(hostname), do: fail!(400, error)

    case Sites.claim_custom_domain(tenant.id, hostname) do
      {:error, :taken} ->
        fail!(409, "That hostname is already in use by another site.")

      {:ok, _} ->
        outcome = Domains.verify_now(tenant.id)

        json(conn, %{
          message:
            if(outcome && outcome.check.ok,
              do: "#{hostname} is verified and live.",
              else: String.trim("Add the DNS record below, then check again. #{(outcome && outcome.check[:reason]) || ""}")
            ),
          site: site_summary(tenant)
        })
    end
  end

  def verify_domain(conn, _) do
    tenant = conn.assigns.tenant
    if not Plans.enterprise?(tenant), do: fail!(403, "A custom domain is part of the enterprise plan.")

    case Domains.verify_now(tenant.id) do
      nil ->
        fail!(404, "No custom domain to check.")

      outcome ->
        json(conn, %{
          message: if(outcome.check.ok, do: "#{outcome.domain.hostname} is verified (#{String.upcase(outcome.check.method)} record found).", else: outcome.check.reason),
          verified: outcome.check.ok,
          site: site_summary(tenant)
        })
    end
  end

  def remove_domain(conn, _) do
    Sites.remove_custom_domain(conn.assigns.tenant.id)
    json(conn, %{message: "Custom domain removed. Your site is back on its platform address.", site: site_summary(conn.assigns.tenant)})
  end

  @doc "For the TLS edge: is this hostname ours to serve? 200 issue, 404 do not."
  def tls_ask(conn, params) do
    domain = (params["domain"] || "") |> to_string() |> String.trim() |> String.downcase()

    ok =
      cond do
        domain == "" or Regex.match?(~r/^\d{1,3}(\.\d{1,3}){3}$/, domain) or String.contains?(domain, ":") -> false
        # One of our own news sites. Its hostname is arbitrary — it is whatever
        # domain we bought — so classify/1 cannot recognise it and the edge has
        # to be told here, or it would never get a certificate for it.
        Rnews1.Publications.find_by_hostname(domain) -> true
        true ->
          where = Hosts.classify(domain)
          where.kind in [:app, :archive] or where[:reserved] == true or (where.kind != :none and Sites.servable_host?(where))
      end

    conn |> no_store() |> put_status(if(ok, do: 200, else: 404)) |> text(if(ok, do: "ok\n", else: "unknown host\n"))
  end
end

defmodule Rnews1Web.EventController do
  @moduledoc "The click beacon: answers 204 whatever happens, then records."
  use Rnews1Web, :controller
  alias Rnews1.Clicks
  alias Rnews1Web.Plugs.RateLimit

  plug RateLimit, :beacon

  @max_events 20
  @uuid ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
  @token ~r/[A-Za-z0-9_-]{40,}/

  def redact(value), do: value |> to_string() |> String.replace(@uuid, ":id") |> String.replace(@token, ":token")

  def collect(conn, _) do
    events = conn.body_params["events"]
    host = conn.host |> to_string() |> String.downcase() |> String.slice(0, 253)
    site = conn.assigns[:site]
    tenant = site && site[:tenant]

    rows =
      if is_list(events) and events != [] and length(events) <= @max_events and host != "" do
        events
        |> Enum.filter(&(is_map(&1) and &1["kind"] in ["link", "button"]))
        |> Enum.map(fn e ->
          %{
            tenant_id: tenant && tenant.id,
            host: host,
            path: e["path"] |> then(&if(is_binary(&1), do: &1, else: "/")) |> String.slice(0, 512) |> redact() |> String.slice(0, 512),
            kind: e["kind"],
            target: if(is_binary(e["target"]), do: e["target"] |> String.slice(0, 512) |> redact() |> String.slice(0, 512)),
            label: if(is_binary(e["label"]), do: String.slice(e["label"], 0, 160)),
            external: e["external"] == true,
            language: tenant && tenant.language
          }
        end)
      else
        []
      end

    valid = length(rows) == length(List.wrap(events)) and rows != []

    if valid do
      try do
        Clicks.record(rows)
      rescue
        e -> require(Logger) && Logger.error("Click events not recorded: #{Exception.message(e)}")
      end
    end

    conn |> put_resp_header("cache-control", "no-store") |> send_resp(204, "")
  end
end

defmodule Rnews1Web.WebhookController do
  use Rnews1Web, :controller
  require Logger
  alias Rnews1.{Billing, MailgunWebhook, PayPal}

  def paypal(conn, _) do
    if not PayPal.configured?() do
      conn |> put_status(503) |> json(%{error: "Payments are not configured."})
    else
      headers = Map.new(conn.req_headers)

      verified =
        try do
          {:ok, PayPal.verify_webhook(headers, conn.body_params)}
        rescue
          e -> {:error, e}
        end

      case verified do
        {:error, e} ->
          Logger.error("PayPal webhook verification unavailable: #{Exception.message(e)}")
          conn |> put_status(503) |> json(%{error: "Verification unavailable."})

        {:ok, false} ->
          conn |> put_status(401) |> json(%{error: "Invalid PayPal signature."})

        {:ok, true} ->
          Billing.process_event(conn.body_params)
          json(conn, %{received: true})
      end
    end
  end

  def mailgun(conn, _) do
    MailgunWebhook.process(conn.body_params)
    send_resp(conn, 200, "")
  end
end

defmodule Rnews1Web.AdController do
  use Rnews1Web, :controller
  require Logger
  alias Rnews1.Ads
  alias Rnews1.Util.{HTML, Ids}

  @pixel Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")

  @doc "Always an image, even for an unknown token: a broken icon in a customer's newsletter is worse than a missing row."
  def pixel(conn, %{"id" => raw}) do
    id = String.replace(raw, ~r/\.gif$/i, "")

    if Ids.uuid?(id) do
      try do
        Ads.record_impression(id)
      rescue
        e -> Logger.error("Impression not recorded: #{Exception.message(e)}")
      end
    end

    conn
    |> put_resp_content_type("image/gif")
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, private")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(200, @pixel)
  end

  def click(conn, %{"id" => id}) do
    if not Ids.uuid?(id), do: fail!(404, "This link is no longer available.")

    case Ads.record_click(id) do
      nil ->
        fail!(404, "This link is no longer available.")

      destination ->
        case HTML.safe_url(destination) do
          "#" -> fail!(404, "This link is no longer available.")
          target -> conn |> no_store() |> redirect(external: target)
        end
    end
  end
end
