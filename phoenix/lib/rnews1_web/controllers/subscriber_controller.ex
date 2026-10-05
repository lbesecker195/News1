defmodule Rnews1Web.SubscriberController do
  use Rnews1Web, :controller
  alias Rnews1.{Content, Env, Subscribers}
  alias Rnews1.Util.Ids
  alias Rnews1Web.Plugs.RateLimit
  import Rnews1Web.Validation

  plug RateLimit, :invite when action in [:add]
  plug :put_brand when action in [:show_confirmation, :confirm, :show_unsubscribe, :unsubscribe]
  plug :same_origin when action in [:confirm]

  defp put_brand(conn, _), do: conn |> assign(:brand, Content.brand()) |> assign(:app_origin, Env.app_origin())
  defp same_origin(conn, _), do: Rnews1Web.Plugs.Origin.require_same_origin(conn, [])

  def add(conn, _) do
    input = recipient!(body(conn))
    Subscribers.add_recipient(%{tenant_id: conn.assigns.tenant.id, email: input.email, authorised_by: conn.assigns.tenant.owner_email})
    json(conn, %{message: "Recipient added. They will receive the next issue."})
  end

  def remove(conn, _) do
    removed = Subscribers.remove(conn.assigns.tenant.id, email!(body(conn)["email"]))
    json(conn, %{ok: true, removed: removed})
  end

  def show_confirmation(conn, %{"token" => token}) do
    if not Ids.uuid?(token), do: fail!(400, "Invalid invitation.")
    conn |> no_store() |> page(title: "Confirm subscription") |> render(:confirm, confirmation_token: token)
  end

  def confirm(conn, %{"token" => token}) do
    if not Ids.uuid?(token), do: fail!(400, "Invalid invitation.")
    confirmed = Subscribers.confirm(token)

    conn
    |> put_status(if(confirmed, do: 200, else: 400))
    |> page(title: "Subscription")
    |> render(:message,
      heading: if(confirmed, do: "You're subscribed.", else: "This invitation is no longer valid."),
      message: if(confirmed, do: "Your daily newsletter will arrive by email.", else: "Ask your account administrator for help.")
    )
  end

  def show_unsubscribe(conn, %{"token" => token}) do
    if not Ids.uuid?(token), do: fail!(400, "Invalid unsubscribe link.")
    conn |> no_store() |> page(title: "Unsubscribe") |> render(:unsubscribe, unsubscribe_token: token)
  end

  @doc "Reached from the page and from a mail client's one-click POST alike."
  def unsubscribe(conn, %{"token" => token}) do
    if not Ids.uuid?(token), do: fail!(400, "Invalid unsubscribe link.")
    Subscribers.unsubscribe(token)

    accepts_html = conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "html"))

    if accepts_html do
      conn
      |> page(title: "Unsubscribed")
      |> render(:message, heading: "You have been unsubscribed.", message: "Marketing and digest emails have been stopped for this address.")
    else
      send_resp(conn, 200, "")
    end
  end
end

defmodule Rnews1Web.SubscriberHTML do
  use Rnews1Web, :html
  embed_templates "subscriber_html/*"

  def message(assigns), do: Rnews1Web.SiteHTML.message(assigns)
end
