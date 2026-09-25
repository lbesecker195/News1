defmodule Rnews1.Subscribers do
  @moduledoc """
  The stakeholder roster. Ten people from the company are meant to be
  involved — an onboarding requirement, not a cap. The owner counts as the
  first; the other nine are collected after payment.
  """
  alias Rnews1.{Companies, DB, HttpError}

  @required 10
  def required_stakeholders, do: @required

  def count_for_tenant(tenant_id) do
    DB.value("SELECT count(*)::int FROM subscribers WHERE tenant_id=$1 AND state <> 'unsubscribed'", [tenant_id])
  end

  @doc "The owner is stakeholder one, enrolled already confirmed. Idempotent."
  def enrol_owner(tenant_id, email) do
    contact =
      DB.one(
        "INSERT INTO contacts(email) VALUES($1) ON CONFLICT(email) DO UPDATE SET email=EXCLUDED.email RETURNING id, opted_out_at, bounced_at",
        [email]
      )

    if contact.opted_out_at || contact.bounced_at do
      false
    else
      DB.execute(
        """
        INSERT INTO subscribers(tenant_id, contact_id, state, confirmed_at) VALUES($1,$2,'active',now())
        ON CONFLICT ON CONSTRAINT subscribers_tenant_contact_key DO NOTHING
        """,
        [tenant_id, contact.id]
      ) > 0
    end
  end

  def list_for_tenant(tenant_id) do
    DB.all(
      "SELECT c.email, s.state FROM subscribers s JOIN contacts c ON c.id=s.contact_id WHERE s.tenant_id=$1 ORDER BY c.email",
      [tenant_id]
    )
  end

  @doc "Adds a recipient on the customer's own authority, in one transaction."
  def add_recipient(%{tenant_id: tenant_id, email: email} = args) do
    DB.transaction(fn ->
      tenant = DB.one("SELECT * FROM tenants WHERE id=$1 FOR UPDATE", [tenant_id])

      if is_nil(tenant) or not Companies.billing_active?(tenant.billing_status) do
        raise HttpError, status: 402, message: "Activate your subscription first."
      end

      contact =
        DB.one("INSERT INTO contacts(email) VALUES($1) ON CONFLICT(email) DO UPDATE SET email=EXCLUDED.email RETURNING *", [
          email
        ])

      if contact.opted_out_at || contact.bounced_at do
        raise HttpError, status: 409, message: "This address is suppressed and cannot be added."
      end

      added =
        DB.one(
          """
          INSERT INTO subscribers(tenant_id, contact_id, state, confirmed_at, authorised_at, authorised_by)
          VALUES($1,$2,'active',now(),now(),$3)
          ON CONFLICT ON CONSTRAINT subscribers_tenant_contact_key
          DO UPDATE SET state='active', confirmed_at=now(), authorised_at=now(), authorised_by=EXCLUDED.authorised_by
          WHERE subscribers.state='unsubscribed'
          RETURNING id
          """,
          [tenant_id, contact.id, Map.get(args, :authorised_by) || tenant.owner_email]
        )

      case added do
        nil -> raise HttpError, status: 409, message: "This recipient is already on your list."
        %{id: id} -> id
      end
    end)
  end

  def remove(tenant_id, email) do
    DB.execute(
      "DELETE FROM subscribers s USING contacts c WHERE s.contact_id=c.id AND s.tenant_id=$1 AND c.email=$2",
      [tenant_id, email]
    ) > 0
  end

  def confirm(confirm_token) do
    DB.execute(
      """
      UPDATE subscribers s SET state='active', confirmed_at=now() FROM contacts c
      WHERE s.contact_id=c.id AND s.confirm_token=$1 AND s.confirm_expires_at>now()
        AND s.state<>'unsubscribed' AND c.opted_out_at IS NULL AND c.bounced_at IS NULL
      """,
      [confirm_token]
    ) > 0
  end

  @doc "An opt-out holds across every tenant, and retracts mail already queued."
  def unsubscribe(unsubscribe_token) do
    DB.transaction(fn ->
      case DB.one("UPDATE contacts SET opted_out_at=COALESCE(opted_out_at,now()) WHERE unsub_token=$1 RETURNING id", [
             unsubscribe_token
           ]) do
        nil ->
          false

        %{id: contact_id} ->
          DB.execute("UPDATE subscribers SET state='unsubscribed' WHERE contact_id=$1 AND state<>'unsubscribed'", [contact_id])

          DB.execute(
            "UPDATE outbox SET status='suppressed' WHERE contact_id=$1 AND status='pending' AND kind<>'login'",
            [contact_id]
          )

          true
      end
    end)
  end
end
