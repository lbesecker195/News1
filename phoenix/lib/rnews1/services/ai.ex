defmodule Rnews1.AI do
  @moduledoc "Chat Completions with a forced JSON object response; retries only transient errors."
  alias Rnews1.{Env, HTTP}

  @timeout 60_000
  @max_retries 4

  def json(instruction, input, opts \\ []) do
    if Env.openai_api_key() == "", do: raise("OPENAI_API_KEY is required")

    model = Keyword.get(opts, :model, Env.openai_model())
    timeout = Keyword.get(opts, :timeout_ms, @timeout)
    max_retries = Keyword.get(opts, :max_retries, @max_retries)

    # The API refuses response_format json_object unless the word "json"
    # appears in the messages; appended centrally so no prompt has to remember.
    messages = [
      %{role: "system", content: "#{instruction}\n\nRespond with JSON only."},
      %{role: "user", content: if(is_binary(input), do: input, else: Jason.encode!(input))}
    ]

    attempt(model, messages, timeout, 0, max_retries)
  end

  defp attempt(model, messages, timeout, n, max_retries) do
    result =
      HTTP.post("https://api.openai.com/v1/chat/completions",
        json: %{model: model, response_format: %{type: "json_object"}, messages: messages},
        headers: [{"authorization", "Bearer #{Env.openai_api_key()}"}],
        receive_timeout: timeout,
        retry: false
      )

    case result do
      {:ok, %{status: status, body: body}} when status == 429 or status >= 500 ->
        retry_or_raise(model, messages, timeout, n, max_retries, "OpenAI #{status}: #{snippet(body)}")

      {:ok, %{status: status, body: body}} when status not in 200..299 ->
        raise "OpenAI #{status}: #{snippet(body)}"

      {:ok, %{body: body}} ->
        content = get_in(body, ["choices", Access.at(0), "message", "content"])

        if not is_binary(content) or String.trim(content) == "" do
          raise "OpenAI returned an empty completion"
        end

        Jason.decode!(strip_fences(content))

      {:error, error} ->
        retry_or_raise(model, messages, timeout, n, max_retries, "OpenAI request failed: #{Exception.message(error)}")
    end
  end

  defp retry_or_raise(model, messages, timeout, n, max_retries, message) do
    if n >= max_retries do
      raise message
    else
      Process.sleep(min(16_000, 500 * Integer.pow(2, n)) + :rand.uniform(250))
      attempt(model, messages, timeout, n + 1, max_retries)
    end
  end

  defp strip_fences(value) do
    value |> String.replace(~r/^```(?:json)?\s*/i, "") |> String.replace(~r/\s*```$/, "") |> String.trim()
  end

  defp snippet(value), do: value |> inspect() |> String.replace(~r/\s+/, " ") |> String.slice(0, 240)
end
