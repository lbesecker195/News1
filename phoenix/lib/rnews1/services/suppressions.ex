defmodule Rnews1.Suppressions do
  @moduledoc """
  Brings the email provider's suppression lists into `contacts`, so RNews1
  stops queueing mail the provider is going to refuse.

  The provider is the authority on who cannot be mailed. A hard bounce adds
  itself to its bounce list, and its complaint and unsubscribe lists catch
  readers who acted in their mail client rather than through our own link. The
  webhook ought to tell us all of this, but this provider's `failed` event
  carries no severity: a permanent bounce and a passing deferral look the same,
  so the webhook cannot tell which address to give up on. Reading the lists
  themselves does not depend on that, and it also catches anything the webhook
  missed while the app was down.

  Only ever adds suppression. An address that leaves a provider list is not
  un-suppressed here: an opt-out belongs to the reader, and a bounce is a dead
  mailbox, so neither is undone by a list changing shape.
  """
  alias Rnews1.{DB, Env, HTTP}

  @lists ~w(bounces complaints unsubscribes)
  @timeout 20_000

  @doc """
  Reads every list and applies it. Returns how many contacts each list newly
  suppressed. Raises if the provider cannot be read, so the caller decides
  whether a failed sync matters.
  """
  def sync do
    Map.new(@lists, fn list -> {String.to_atom(list), list |> fetch() |> apply_list(list)} end)
  end

  @doc "Whether there is a provider to read at all; a blank key means mail is not configured."
  def configured?, do: Env.mailgun_api_key() != "" and Env.mailgun_domain() != ""

  defp fetch(list) do
    case HTTP.get("#{Env.mailgun_api_base()}/v3/#{Env.mailgun_domain()}/#{list}",
           params: [limit: 1000],
           auth: {:basic, "api:#{Env.mailgun_api_key()}"},
           receive_timeout: @timeout,
           retry: false
         ) do
      {:ok, %{status: status, body: %{"items" => items}}}
      when status in 200..299 and is_list(items) ->
        items
        |> Enum.map(&normalise(&1["address"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok, %{status: status}} ->
        raise "Reading the #{list} list returned #{status}."

      {:error, error} ->
        raise "Reading the #{list} list did not complete: #{Exception.message(error)}"
    end
  end

  defp normalise(address) when is_binary(address) do
    case address |> String.trim() |> String.downcase() do
      "" -> nil
      address -> address
    end
  end

  defp normalise(_), do: nil

  defp apply_list([], _list), do: 0

  # A bounce is a dead mailbox: no list may mail it, but the reader made no
  # choice, so their subscriptions stay as they were — the same as the webhook
  # does for a hard bounce.
  defp apply_list(addresses, "bounces") do
    DB.transaction(fn ->
      marked =
        DB.execute(
          "UPDATE contacts SET bounced_at = now() WHERE email = ANY($1::citext[]) AND bounced_at IS NULL",
          [addresses]
        )

      cancel_pending(addresses)
      marked
    end)
  end

  # A complaint or an unsubscribe is the reader's choice, and it stops every
  # list, so it is recorded the way the one-click link records it.
  defp apply_list(addresses, _complaints_or_unsubscribes) do
    DB.transaction(fn ->
      marked =
        DB.execute(
          "UPDATE contacts SET opted_out_at = now() WHERE email = ANY($1::citext[]) AND opted_out_at IS NULL",
          [addresses]
        )

      DB.execute(
        """
        UPDATE subscribers s SET state = 'unsubscribed' FROM contacts c
        WHERE c.id = s.contact_id AND c.email = ANY($1::citext[]) AND s.state <> 'unsubscribed'
        """,
        [addresses]
      )

      cancel_pending(addresses)
      marked
    end)
  end

  # Mail already queued for a suppressed address would only be refused.
  # Sign-in links are left alone: someone may bounce our newsletter and still
  # need to reach their account.
  defp cancel_pending(addresses) do
    DB.execute(
      """
      UPDATE outbox o SET status = 'suppressed', last_error = 'suppressed by the provider'
      FROM contacts c
      WHERE c.id = o.contact_id AND c.email = ANY($1::citext[])
        AND o.status = 'pending' AND o.kind <> 'login'
      """,
      [addresses]
    )
  end
end
