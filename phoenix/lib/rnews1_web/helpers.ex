defmodule Rnews1Web.ControllerHelpers do
  @moduledoc "Small things every controller does."
  import Plug.Conn
  alias Rnews1.HttpError

  def no_store(conn), do: put_resp_header(conn, "cache-control", "private, no-store")
  def public_cache(conn, seconds), do: put_resp_header(conn, "cache-control", "public, max-age=#{seconds}")

  def fail!(status, message), do: raise(HttpError, status: status, message: message)

  @doc "A page render with the layout's optional assigns defaulted."
  def page(conn, assigns \\ []) do
    conn
    |> assign(:page_title, assigns[:title] || conn.assigns[:page_title] || "Rnews1")
    |> merge_assigns(assigns)
  end

  def cookie_opts(extra \\ []) do
    Keyword.merge([http_only: true, secure: Rnews1.Env.https?(), same_site: "Lax", path: "/"], extra)
  end

  def body(conn), do: conn.body_params
end

defmodule Rnews1Web.ViewHelpers do
  @moduledoc "Formatting helpers for templates."

  def money(cents) when is_integer(cents), do: :erlang.float_to_binary(cents / 100, decimals: 2)
  def money(_), do: "0.00"

  def date_slug(%Date{} = d), do: Date.to_iso8601(d)
  def date_slug(%DateTime{} = d), do: d |> DateTime.to_date() |> Date.to_iso8601()
  def date_slug(other), do: to_string(other || "")

  def lower(value), do: value |> to_string() |> String.downcase()
end
