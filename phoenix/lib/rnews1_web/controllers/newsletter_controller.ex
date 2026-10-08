defmodule Rnews1Web.NewsletterController do
  @moduledoc """
  A news site's own newsletter, seen from the account that owns the site.

  Every list belongs to one site, so every action here is scoped to one
  publication and the account is only allowed near a publication it holds. A
  slug nobody owns answers 404 rather than 403: the safe way to read somebody
  else's site is to be unable to tell it apart from one that does not exist.
  """
  use Rnews1Web, :controller
  alias Rnews1.{Env, Newsletter, Publications}
  alias Rnews1.Util.Hosts
  import Rnews1Web.Validation

  # Resolved inside the action rather than in a plug: `fail!` is only turned
  # into a response under `action/2`, and a plug raising it would escape as a
  # 500 instead of the 404 it names.
  defp publication!(conn) do
    Publications.find_slug_for_tenant(conn.params["slug"], conn.assigns.tenant.id) ||
      fail!(404, "No such site on this account.")
  end

  def show(conn, _) do
    publication = publication!(conn)
    subscribers = Newsletter.subscribers(publication)
    origin = Hosts.publication_origin(publication)

    json(conn, %{
      name: publication.name,
      subscribers: subscribers,
      # What the next edition would actually go to, which is the list less
      # anyone who has opted out or bounced since signing up.
      receiving: Enum.count(subscribers, &(not &1.suppressed)),
      editions: Newsletter.recent_editions(publication),
      sendingHour: Env.edition_hour(),
      webUrl: origin <> "/newsletter",
      signupUrl: origin <> "/en"
    })
  end

  def remove(conn, _) do
    removed = Newsletter.remove(publication!(conn), email!(body(conn)["email"]))
    json(conn, %{ok: true, removed: removed})
  end
end
