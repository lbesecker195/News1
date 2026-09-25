defmodule Rnews1Web.ErrorHTML do
  @moduledoc """
  Errors as the message page, in the chrome of whichever host asked. An
  HttpError carries its own words; anything else is a plain status.
  """
  use Rnews1Web, :html

  def render(template, assigns) do
    status = template |> String.split(".") |> List.first() |> String.to_integer()
    reason = assigns[:reason]
    conn = assigns[:conn]

    message =
      case reason do
        %Rnews1.HttpError{message: message} -> message
        _ when status == 404 -> "The requested page is unavailable."
        _ -> "Request failed. Please try again or contact support."
      end

    heading = if status == 404, do: "Page not found", else: "We couldn't complete that request"

    page_assigns =
      %{
        page_title: if(status == 404, do: "Not found", else: "Request failed"),
        heading: heading,
        message: message,
        brand: Rnews1.Content.brand(),
        app_origin: Rnews1.Env.app_origin(),
        indexable: false,
        signed_in: false
      }
      |> Map.merge(Map.take((conn && conn.assigns) || %{}, [:site, :archive, :offsite, :signed_in]))

    Phoenix.Template.render_to_string(Rnews1Web.Layouts, "root", "html",
      Map.put(page_assigns, :inner_content, Rnews1Web.SiteHTML.message(page_assigns))
    )
    |> Phoenix.HTML.raw()
  end
end

defmodule Rnews1Web.ErrorJSON do
  def render(template, assigns) do
    status = template |> String.split(".") |> List.first() |> String.to_integer()

    message =
      case assigns[:reason] do
        %Rnews1.HttpError{message: message} -> message
        _ when status == 404 -> "Not found."
        _ when status == 400 -> "Invalid input."
        _ -> "Request failed. Please try again or contact support."
      end

    %{error: message}
  end
end
