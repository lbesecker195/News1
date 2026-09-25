defmodule Rnews1Web.Errors do
  @moduledoc "Turns an HttpError into the response it names, in the chrome of whichever host asked."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2, put_view: 2, put_root_layout: 2, render: 3, get_format: 1]

  def send_http_error(conn, %Rnews1.HttpError{status: status, message: message}) do
    if json?(conn) do
      conn |> put_status(status) |> json(%{error: message})
    else
      conn
      |> put_status(status)
      |> assign(:brand, Rnews1.Content.brand())
      |> assign(:app_origin, Rnews1.Env.app_origin())
      |> assign(:page_title, if(status == 404, do: "Not found", else: "Request failed"))
      |> put_root_layout(html: {Rnews1Web.Layouts, :root})
      |> put_view(html: Rnews1Web.SiteHTML)
      |> render(:message,
        heading: if(status == 404, do: "Page not found", else: "We couldn't complete that request"),
        message: message
      )
    end
  end

  def not_found(conn, _params) do
    send_http_error(conn, %Rnews1.HttpError{status: 404, message: "The requested page is unavailable."})
  end

  defp json?(conn) do
    String.starts_with?(conn.request_path, "/api/") or String.starts_with?(conn.request_path, "/webhooks/") or
      conn.request_path == "/e" or get_format(conn) == "json"
  end
end

defmodule Rnews1Web.NotFoundController do
  use Rnews1Web, :controller
  def not_found(conn, params), do: Rnews1Web.Errors.not_found(conn, params)
end
