defmodule Rnews1Web.Dispatch do
  @moduledoc "Three routers, one per kind of host. Customer hosts never reach the app's routes."
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:host_kind] do
      :archive -> Rnews1Web.ArchiveRouter.call(conn, Rnews1Web.ArchiveRouter.init([]))
      :site -> Rnews1Web.SiteRouter.call(conn, Rnews1Web.SiteRouter.init([]))
      _ -> Rnews1Web.Router.call(conn, Rnews1Web.Router.init([]))
    end
  end
end
