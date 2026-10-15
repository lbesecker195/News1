defmodule Rnews1.SuppressionsTest do
  @moduledoc """
  The provider's bounce, complaint and unsubscribe lists, brought into contacts
  so RNews1 stops queueing mail the provider will refuse.
  """
  use Rnews1.DataCase, async: false
  alias Rnews1.{DB, Digests, Outbox, Subscribers, Suppressions}

  setup do
    previous = Application.get_env(:rnews1, :req_options)
    Application.put_env(:rnews1, :req_options, plug: {Req.Test, Rnews1.HTTP})
    on_exit(fn -> Application.put_env(:rnews1, :req_options, previous || []) end)
    :ok
  end

  # Answers each list from `lists`, and records which lists were asked for.
  defp provider(lists) do
    test = self()

    Req.Test.stub(Rnews1.HTTP, fn conn ->
      list = conn.path_info |> List.last()
      send(test, {:read, list, conn.query_string})
      addresses = Map.get(lists, list, [])

      Req.Test.json(conn, %{
        "items" => Enum.map(addresses, &%{"address" => &1}),
        "total_count" => length(addresses)
      })
    end)
  end

  defp contact(email), do: DB.one("SELECT * FROM contacts WHERE email = $1", [email])

  test "reads all three lists from the sending domain" do
    provider(%{})
    Suppressions.sync()

    for list <- ~w(bounces complaints unsubscribes) do
      assert_received {:read, ^list, query}
      assert query =~ "limit=1000"
    end
  end

  test "a bounced address stops being mailed, and its waiting mail is cancelled" do
    %{tenant_id: tenant_id} = paid_tenant(stakeholders: 2)
    dead = "stakeholder0@acme.test"
    %{id: dead_id} = contact(dead)

    Outbox.enqueue(%{
      contact_id: dead_id,
      tenant_id: tenant_id,
      to_email: dead,
      kind: "digest",
      payload: %{}
    })

    provider(%{"bounces" => ["  Stakeholder0@Acme.TEST "]})

    assert %{bounces: 1, complaints: 0, unsubscribes: 0} = Suppressions.sync()
    assert contact(dead).bounced_at
    assert DB.value("SELECT status FROM outbox WHERE contact_id = $1", [dead_id]) == "suppressed"

    # The next issue goes only to the address that still works.
    recipients =
      Digests.with_tenant_due_for_digest("2026-09-11", fn t ->
        Enum.map(t.recipients, & &1.email)
      end)

    refute dead in recipients
    assert "stakeholder1@acme.test" in recipients
  end

  test "a bounce leaves the reader's subscriptions as they were; it was not their choice" do
    paid_tenant(stakeholders: 1)
    provider(%{"bounces" => ["stakeholder0@acme.test"]})
    Suppressions.sync()

    assert DB.value(
             "SELECT s.state FROM subscribers s JOIN contacts c ON c.id = s.contact_id WHERE c.email = 'stakeholder0@acme.test'"
           ) == "active"

    assert is_nil(contact("stakeholder0@acme.test").opted_out_at)
  end

  test "a complaint or an unsubscribe opts the reader out of every list" do
    paid_tenant(stakeholders: 2)

    provider(%{
      "complaints" => ["stakeholder0@acme.test"],
      "unsubscribes" => ["stakeholder1@acme.test"]
    })

    assert %{complaints: 1, unsubscribes: 1} = Suppressions.sync()

    for email <- ["stakeholder0@acme.test", "stakeholder1@acme.test"] do
      assert contact(email).opted_out_at, email

      assert DB.value(
               "SELECT s.state FROM subscribers s JOIN contacts c ON c.id = s.contact_id WHERE c.email = $1",
               [email]
             ) == "unsubscribed",
             email
    end
  end

  test "running again changes nothing and keeps the first date" do
    paid_tenant(stakeholders: 1)
    provider(%{"bounces" => ["stakeholder0@acme.test"]})

    assert %{bounces: 1} = Suppressions.sync()
    first = contact("stakeholder0@acme.test").bounced_at

    assert %{bounces: 0} = Suppressions.sync()
    assert contact("stakeholder0@acme.test").bounced_at == first
  end

  test "an address RNews1 has never heard of is ignored" do
    provider(%{"bounces" => ["stranger@elsewhere.test"]})

    assert %{bounces: 0} = Suppressions.sync()
    assert is_nil(contact("stranger@elsewhere.test"))
  end

  test "a sign-in link is never cancelled, even for an address that bounces our newsletter" do
    paid_tenant(stakeholders: 1)
    %{id: id} = contact("stakeholder0@acme.test")

    Outbox.enqueue(%{
      contact_id: id,
      to_email: "stakeholder0@acme.test",
      kind: "login",
      payload: %{url: "u"}
    })

    provider(%{"bounces" => ["stakeholder0@acme.test"]})

    Suppressions.sync()

    assert DB.value("SELECT status FROM outbox WHERE kind = 'login' AND contact_id = $1", [id]) ==
             "pending"
  end

  test "a provider that cannot be read raises, so maintenance can log it and carry on" do
    Req.Test.stub(Rnews1.HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "busy") end)
    assert_raise RuntimeError, ~r/bounces list returned 503/, fn -> Suppressions.sync() end

    Req.Test.stub(Rnews1.HTTP, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert_raise RuntimeError, ~r/did not complete/, fn -> Suppressions.sync() end
  end

  test "a bounced address can no longer be put back on a list" do
    %{tenant_id: tenant_id} = paid_tenant()
    provider(%{"bounces" => ["gone@acme.test"]})

    DB.execute("INSERT INTO contacts(email) VALUES('gone@acme.test')", [])
    Suppressions.sync()

    assert_raise Rnews1.HttpError, ~r/suppressed/, fn ->
      Subscribers.add_recipient(%{
        tenant_id: tenant_id,
        email: "gone@acme.test",
        authorised_by: "owner@acme.test"
      })
    end
  end
end
