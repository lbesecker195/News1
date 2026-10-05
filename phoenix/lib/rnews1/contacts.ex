defmodule Rnews1.Contacts do
  @moduledoc """
  Whose list an address is on, and so who may mail it.

  Every list belongs to one site. An address a customer added is on that
  customer's list and gets that customer's newsletter, nothing else. An address
  typed into a news site's sign-up form gets that site's edition, nothing else.
  www.rnews1.com is a site like any other and builds its own list the same way.

  RNews1's own contacts are the addresses RNews1 brought in itself, and they are
  the only ones it mails for its own purposes: the www edition's business
  contacts and the outreach campaign. An address counts only when its row
  records where it came from (`source`, which an import sets and a customer's
  list never does: `Subscribers` inserts the bare address), and only while it is
  on nobody's list. Being on any list — a customer's, or any site's sign-ups,
  www's included — makes the address that list's reader and nothing more,
  whichever came first, and an account owner is a customer, not a prospect. An
  address with no source is never adopted, so a reader a customer has since
  removed does not become RNews1's to mail.

  Suppression is the one thing shared across lists: an opt-out or bounce stops
  every RNews1 email to the address, whichever list it came from.
  """
  alias Rnews1.DB

  @own """
  c.opted_out_at IS NULL AND c.bounced_at IS NULL
    AND c.source IS NOT NULL AND c.source <> 'newsletter'
    AND NOT EXISTS (SELECT 1 FROM subscribers s WHERE s.contact_id = c.id)
    AND NOT EXISTS (SELECT 1 FROM newsletter_subscriptions n WHERE n.contact_id = c.id)
    AND NOT EXISTS (SELECT 1 FROM tenants t WHERE t.owner_email = c.email)
  """

  @doc """
  The SQL condition, over `contacts` aliased `c`, for an address that is one of
  RNews1's own contacts and may be mailed now.
  """
  def rnews1_own_sql, do: @own

  @doc "Whether the contact is one of RNews1's own and may be mailed now."
  def rnews1_own?(nil), do: false

  def rnews1_own?(contact_id) do
    DB.value("SELECT EXISTS (SELECT 1 FROM contacts c WHERE c.id = $1 AND #{@own})", [contact_id])
  end
end
