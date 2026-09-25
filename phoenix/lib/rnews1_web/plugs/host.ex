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
  alias Rnews1.Sites
  alias Rnews1.Util.Hosts

  def init(opts), do: opts

  def call(conn, _opts) do
    where = Hosts.classify(conn.host)

    case where.kind do
      :app ->
        assign(conn, :host_kind, :app)

      :archive ->
        conn
        |> assign(:host_kind, :archive)
        |> assign(:archive, true)
        |> assign(:offsite, true)

      _ ->
        tenant = lookup(where)

        cond do
          is_nil(tenant) and where.kind == :subdomain and where.reserved ->
            assign(conn, :host_kind, :app)

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
  end

  defp lookup(%{kind: :subdomain, label: label}), do: Sites.find_by_subdomain(label) || Sites.find_by_old_subdomain(label)
  defp lookup(%{kind: :custom, host: host}), do: Sites.find_by_custom_hostname(host)
  defp lookup(_), do: nil

  defp query(%{query_string: ""}), do: ""
  defp query(%{query_string: qs}), do: "?" <> qs
end
