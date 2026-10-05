defmodule Rnews1.Newsletter do
  @moduledoc """
  Who receives a publication's daily edition.

  Two groups, told different things in the footer because what is true of them
  differs:

    * subscribers — typed their address on that publication's own site. Every
      address entered is taken as opted in, so the subscription is live the
      moment the form is sent; there is no confirmation step. Told "you
      subscribed at <host>".
    * business contacts — RNews1's own contacts (`Rnews1.Contacts`), who never
      used a sign-up form. Told they are receiving it as a business contact.
      They get the archive's edition only, never one per publication: a
      contact who signed up for nothing should not find several of our emails
      a day.

  Every list belongs to its own site, so nobody else is in either group: a
  customer's readers get that customer's newsletter, and a reader who signed
  up on one publication gets that one. An address that has opted out or
  bounced is suppressed everywhere, as it is for every other RNews1 email.
  """
  alias Rnews1.{Contacts, DB, Env, Publications}

  @email ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @doc """
  Subscribes the address to the publication's daily edition.

  Answers `:ok` whatever happened — new, already subscribed, suppressed — so
  the public form cannot be used to learn whether an address is on a list or
  has opted out. Only a malformed address is refused.
  """
  def subscribe(publication, email) do
    email = email |> to_string() |> String.trim() |> String.downcase()

    if String.length(email) > 254 or not Regex.match?(@email, email) do
      {:error, :invalid_email}
    else
      DB.transaction(fn -> start(publication, email) end)
      :ok
    end
  end

  defp start(publication, email) do
    contact =
      DB.one(
        """
        INSERT INTO contacts(email, source) VALUES($1, 'newsletter') ON CONFLICT(email) DO UPDATE SET email = EXCLUDED.email
        RETURNING id, opted_out_at, bounced_at
        """,
        [email]
      )

    # A suppressed address stays suppressed: typing it into a form does not
    # undo an opt-out or a bounce, here or anywhere else on the platform.
    unless contact.opted_out_at || contact.bounced_at do
      DB.execute(
        """
        INSERT INTO newsletter_subscriptions(publication_id, contact_id) VALUES($1, $2)
        ON CONFLICT ON CONSTRAINT newsletter_subscriptions_pub_contact_key DO NOTHING
        """,
        [publication.id, contact.id]
      )
    end
  end

  @doc """
  Everyone a publication's edition goes to today, each with the reason the
  footer gives them. One entry per contact, a subscription taking precedence
  over being a business contact.
  """
  def audience(publication) do
    subscribers =
      DB.all(
        """
        SELECT c.id AS contact_id, c.email, c.unsub_token
        FROM newsletter_subscriptions s JOIN contacts c ON c.id = s.contact_id
        WHERE s.publication_id = $1
          AND c.opted_out_at IS NULL AND c.bounced_at IS NULL
        ORDER BY s.created_at
        """,
        [publication.id]
      )
      |> Enum.map(&Map.put(&1, :reason, :subscribed))

    contacts =
      if publication.slug == Publications.default_slug(),
        do: business_contacts(),
        else: []

    subscribers ++ contacts
  end

  # Nobody here is also a subscriber: an address on any site's sign-ups, this
  # one's included, is not one of RNews1's own contacts.
  defp business_contacts do
    DB.all(
      """
      SELECT c.id AS contact_id, c.email, c.unsub_token
      FROM contacts c
      WHERE #{Contacts.rnews1_own_sql()}
      ORDER BY c.created_at
      """,
      []
    )
    |> Enum.map(&Map.put(&1, :reason, :contact))
  end

  def unsubscribe_url(%{unsub_token: token}), do: "#{Env.app_origin()}/u/#{token}"
end
