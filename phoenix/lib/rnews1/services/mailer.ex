defmodule Rnews1.Mailer do
  @moduledoc "Sending through Mailgun; an unknown outcome is never retried."
  alias Rnews1.{Env, HTTP}

  @timeout 20_000

  defmodule Error do
    defexception [:message, status: 0, retryable: false, unknown: false]
  end

  @doc "Returns {:ok, message_id} or raises Rnews1.Mailer.Error."
  def send_email(%{to: to, subject: subject} = m) do
    form =
      [from: Env.mailgun_from(), to: to, subject: subject] ++
        if(m[:text], do: [text: m[:text]], else: []) ++
        if(m[:html], do: [html: m[:html]], else: []) ++
        if(m[:job_id], do: [{:"v:job_id", m[:job_id]}], else: []) ++
        if(m[:tag], do: [{:"o:tag", m[:tag]}], else: []) ++
        Enum.map(m[:headers] || %{}, fn {name, value} -> {String.to_atom("h:#{name}"), value} end)

    case HTTP.post("#{Env.mailgun_api_base()}/v3/#{Env.mailgun_domain()}/messages",
           form_multipart: form,
           auth: {:basic, "api:#{Env.mailgun_api_key()}"},
           receive_timeout: @timeout,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, if(is_map(body), do: body["id"], else: nil)}

      {:ok, %{status: status, body: body}} ->
        raise Error,
          message: "Mailgun #{status}: #{body |> inspect() |> String.slice(0, 240)}",
          status: status,
          retryable: status == 429 or status >= 500

      {:error, error} ->
        raise Error, message: "Mailgun request did not complete: #{Exception.message(error)}", unknown: true
    end
  end

  def verify_mailgun do
    case HTTP.get("#{Env.mailgun_api_base()}/v3/domains/#{Env.mailgun_domain()}",
           auth: {:basic, "api:#{Env.mailgun_api_key()}"},
           receive_timeout: @timeout,
           retry: false
         ) do
      {:ok, %{status: 401}} -> raise "Mailgun rejected the API key."
      {:ok, %{status: 404}} -> raise "Mailgun does not have the domain #{Env.mailgun_domain()} on this account."
      {:ok, %{status: status}} when status not in 200..299 -> raise "Mailgun returned #{status}."
      {:ok, %{body: body}} ->
        %{domain: Env.mailgun_domain(), sandbox: Regex.match?(~r/^sandbox/i, Env.mailgun_domain()), state: get_in(body, ["domain", "state"]) || "unknown"}
      {:error, error} -> raise "Mailgun unreachable: #{Exception.message(error)}"
    end
  end
end

defmodule Rnews1.MailgunWebhook do
  @moduledoc "Verifies the signature Mailgun puts inside the JSON body, then applies the event."
  alias Rnews1.{Env, HttpError, MailgunEvents}
  alias Rnews1.Util.Ids

  @max_skew 86_400

  def process(body, apply \\ &MailgunEvents.record_and_apply/1) do
    signature = (is_map(body) && body["signature"]) || %{}
    timestamp = to_string(signature["timestamp"] || "")
    token = to_string(signature["token"] || "")
    supplied = to_string(signature["signature"] || "")

    now = System.os_time(:second)

    valid_shape =
      Regex.match?(~r/^\d+$/, timestamp) and abs(now - String.to_integer(timestamp)) <= @max_skew and
        Regex.match?(~r/^[a-f0-9]{64}$/i, supplied)

    if not valid_shape, do: raise(HttpError, status: 403, message: "Invalid Mailgun signature.")

    expected = :crypto.mac(:hmac, :sha256, Env.mailgun_signing_key(), timestamp <> token)

    with {:ok, given} <- Base.decode16(supplied, case: :mixed),
         true <- Plug.Crypto.secure_compare(expected, given) do
      :ok
    else
      _ -> raise HttpError, status: 403, message: "Invalid Mailgun signature."
    end

    data = body["event-data"]

    if not is_map(data) or is_nil(data["id"]) or is_nil(data["event"]),
      do: raise(HttpError, status: 400, message: "Invalid Mailgun event.")

    job_id = get_in(data, ["user-variables", "job_id"])
    kind = if data["event"] == "failed" and data["severity"] == "permanent", do: "hard_bounce", else: data["event"]

    apply.(%{
      id: to_string(data["id"]),
      kind: kind,
      job_id: if(Ids.uuid?(job_id), do: job_id, else: nil),
      email: (data["recipient"] || "") |> to_string() |> String.trim() |> String.downcase()
    })
  end
end
