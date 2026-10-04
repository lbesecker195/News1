defmodule Rnews1Web.Plugs.Host do
  @moduledoc """
  Decides whose site a request is for, from the Host header, and marks the
  conn so the dispatcher can hand it to the right router. A non-canonical
  host for a tenant — an old subdomain still in its redirect window, or the
  platform subdomain once a custom domain is verified — is 301'd to the
  canonical one with its path intact.
  """
  @behaviour Plug
  import Plug.Conn
  alias Rnews1.{Publications, Sites}
  alias Rnews1.Util.Hosts

  def init(opts), do: opts

  def call(conn, _opts) do
    where = Hosts.classify(conn.host)

    case where.kind do
      :app ->
        assign(conn, :host_kind, :app)

      :archive ->
        archive(conn, Publications.find_by_hostname(conn.host) || Publications.default())

      _ ->
        # A publication is looked up before a tenant. Both can hold a hostname
        # that classify/1 calls :custom, and an editorial site of ours is not a
        # customer's briefing — whichever row exists decides which router runs.
        case Publications.find_by_hostname(where.host) do
          %{} = publication -> archive(conn, publication)
          nil -> tenant_host(conn, where)
        end
    end
  end

  defp archive(conn, publication) do
    conn
    |> assign(:host_kind, :archive)
    |> assign(:archive, true)
    |> assign(:publication, publication)
    |> assign(:offsite, true)
  end

  defp tenant_host(conn, where) do
    tenant = lookup(where)

    cond do
      # A platform subdomain with no site behind it — never claimed, malformed,
      # or a reserved label — goes to the app, where the visitor can start one.
      #
      # 302, deliberately, not 301. Browsers cache a 301 for good, and a label
      # that is free today is one anybody can claim tomorrow: a cached permanent
      # redirect would keep sending people past a customer's real site.
      #
      # Old labels still in their redirect window never reach here: lookup/1
      # found the tenant through subdomain_history, and the canonical 301 below
      # takes them. Custom domains are left alone too, since one with no tenant
      # is usually a customer partway through setting it up.
      is_nil(tenant) and where.kind in [:subdomain, :none] ->
        conn
        |> put_resp_header("location", Rnews1.Env.app_origin() <> "/")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(302, "")
        |> halt()

      is_nil(tenant) ->
        conn
        |> assign(:host_kind, :site)
        |> assign(:site, %{host: where.host, tenant: nil})
        |> assign(:offsite, true)

      true ->
        origin = Hosts.site_origin(tenant)

        if URI.parse(origin).host != where.host do
          conn
          |> put_resp_header("location", origin <> conn.request_path <> query(conn))
          |> send_resp(301, "")
          |> halt()
        else
          site = %{host: where.host, tenant: tenant, origin: origin, published: Sites.published?(tenant)}

          conn
          |> assign(:host_kind, :site)
          |> assign(:site, site)
          |> assign(:offsite, true)
        end
    end
  end

  defp lookup(%{kind: :subdomain, label: label}), do: Sites.find_by_subdomain(label) || Sites.find_by_old_subdomain(label)
  defp lookup(%{kind: :custom, host: host}), do: Sites.find_by_custom_hostname(host)
  defp lookup(_), do: nil

  defp query(%{query_string: ""}), do: ""
  defp query(%{query_string: qs}), do: "?" <> qs
end
