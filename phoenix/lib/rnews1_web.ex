defmodule Rnews1Web do
  @moduledoc "The entrypoint for the web interface: `use Rnews1Web, :controller` and `:html`."

  # Served at the root, as the Node app served them: /site.css, /app.js …
  def static_paths, do: ~w(site.css app.js track.js article.js topics.js favicon.ico)

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      import Plug.Conn
      import Rnews1Web.ControllerHelpers
      alias Rnews1.HttpError

      # An HttpError raised anywhere under an action is the response it names —
      # JSON on the API, the message page elsewhere — never a crash.
      def action(conn, _opts) do
        apply(__MODULE__, action_name(conn), [conn, conn.params])
      rescue
        e in Rnews1.HttpError -> Rnews1Web.Errors.send_http_error(conn, e)
      end

      defoverridable action: 2
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.HTML
      import Rnews1Web.ViewHelpers
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
