defmodule Rnews1Web.Validation do
  @moduledoc "Input shapes, raising 400s with the message the Node app gave."
  alias Rnews1.HttpError

  @email ~r/^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/

  def email!(value) do
    email = value |> to_string() |> String.trim() |> String.downcase()
    if String.length(email) <= 254 and Regex.match?(@email, email), do: email, else: raise(HttpError, status: 400, message: "Enter a valid email address.")
  end

  def email?(value), do: match?({:ok, _}, safe(fn -> email!(value) end))

  def string!(value, opts) do
    text = value |> to_string() |> String.trim()
    min = Keyword.get(opts, :min, 0)
    max = Keyword.get(opts, :max, 10_000)
    if String.length(text) < min or String.length(text) > max, do: raise(HttpError, status: 400, message: "Invalid input."), else: text
  end

  @keyword_count 2
  def keyword_count, do: @keyword_count

  def company!(params) do
    keywords = params["keywords"] |> List.wrap() |> Enum.map(&(&1 |> to_string() |> String.trim())) |> Enum.reject(&(&1 == ""))
    language = params["language"]

    if length(keywords) != @keyword_count, do: raise(HttpError, status: 400, message: "Choose exactly #{@keyword_count} keywords.")
    if Enum.any?(keywords, &(String.length(&1) > 60)), do: raise(HttpError, status: 400, message: "Invalid input.")
    if language not in ~w(en es fr de), do: raise(HttpError, status: 400, message: "Invalid input.")

    %{
      name: string!(params["name"], min: 1, max: 100),
      domain: string!(params["domain"], min: 1, max: 253),
      industry: string!(params["industry"], min: 1, max: 100),
      keywords: keywords,
      language: language
    }
  end

  def suggestion_input!(params) do
    %{name: string!(params["name"] || "", max: 100), domain: string!(params["domain"] || "", max: 253), industry: string!(params["industry"] || "", max: 100)}
  end

  def recipient!(params) do
    if params["authorised"] != true, do: raise(HttpError, status: 400, message: "Invalid input.")
    %{email: email!(params["email"]), authorised: true}
  end

  def date!(value) do
    case Date.from_iso8601(to_string(value || "")) do
      {:ok, date} -> date
      _ -> raise HttpError, status: 400, message: "Invalid input."
    end
  end

  def uuid!(value) do
    if Rnews1.Util.Ids.uuid?(value), do: value, else: raise(HttpError, status: 400, message: "Invalid input.")
  end

  def int!(value, min, max) do
    parsed =
      case value do
        v when is_integer(v) -> v
        v when is_binary(v) -> case Integer.parse(String.trim(v)), do: ({n, ""} -> n; _ -> nil)
        _ -> nil
      end

    if is_nil(parsed) or parsed < min or parsed > max, do: raise(HttpError, status: 400, message: "Invalid input."), else: parsed
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    HttpError -> :error
  end
end
