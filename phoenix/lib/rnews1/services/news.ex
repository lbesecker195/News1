defmodule Rnews1.News do
  @moduledoc """
  Finding the day's candidate stories through treg, which returns the
  publisher's own URL. Failure here is never fatal: an empty list means a thin
  issue, not a dead worker.
  """
  require Logger
  alias Rnews1.{Env, HTTP}

  @timeout 20_000
  @max_items 12
  @recency_days 2

  @providers %{"exa" => "exa.web.search.news", "serp" => "treg.google.serp.news"}
  def providers, do: @providers

  @doc "The stored topic query is Google syntax; exa reads plain language better."
  def plain_query(query) do
    (query || "")
    |> to_string()
    |> String.replace("\"", " ")
    |> String.replace(~r/\bOR\b/i, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def fetch_topic_items(opts \\ []) do
    query = Keyword.get(opts, :query)
    language = Keyword.get(opts, :language, "en")
    provider = Keyword.get(opts, :provider, Env.news_provider())

    if is_nil(query) or query == "" do
      []
    else
      endpoint = Map.get(@providers, provider, @providers["exa"])

      floor =
        Keyword.get(opts, :since) ||
          DateTime.utc_now() |> DateTime.add(-@recency_days * 86_400, :second) |> DateTime.to_iso8601()

      body =
        if provider == "serp",
          do: %{q: query, language: language, country: "us"},
          else: %{query: plain_query(query), category: "news", numResults: @max_items, startPublishedDate: floor}

      try do
        response = call_treg(endpoint, body)
        items = if provider == "serp", do: from_serp(response), else: from_exa(response)
        items |> dedupe() |> Enum.take(@max_items)
      rescue
        e ->
          Logger.error("News discovery failed (#{provider}): #{Exception.message(e)}")
          []
      end
    end
  end

  defp call_treg(endpoint, body) do
    if Env.treg_token() == "", do: raise("TREG_TOKEN is not set")

    case HTTP.post("#{Env.treg_base_url()}/call/#{endpoint}",
           json: body,
           headers: [{"x-treg-token", Env.treg_token()}],
           receive_timeout: @timeout
         ) do
      {:ok, %{status: status, body: payload, headers: headers}} when status in 200..299 ->
        case Map.get(headers, "x-treg-cost-micro") do
          [cost | _] when cost not in [nil, "0"] ->
            Logger.info("treg #{endpoint}: $#{Float.round(String.to_integer(cost) / 1_000_000, 4)}")

          _ ->
            :ok
        end

        payload

      {:ok, %{status: status, body: text}} ->
        hint =
          case status do
            402 -> " — treg balance is empty, top up at treg.to"
            503 -> " — provider capacity unavailable, try the other NEWS_PROVIDER"
            _ -> ""
          end

        raise "treg #{status}#{hint}: #{text |> inspect() |> String.slice(0, 200)}"

      {:error, error} ->
        raise "treg request failed: #{Exception.message(error)}"
    end
  end

  defp from_exa(%{"results" => results}) when is_list(results) do
    Enum.map(results, fn row ->
      item(row["url"], row["title"], publisher_from(row["url"]), row["publishedDate"])
    end)
  end

  defp from_exa(_), do: []

  defp from_serp(payload) do
    rows = get_in(payload, ["output", "results"]) || payload["results"] || get_in(payload, ["raw", "results"]) || []

    rows
    |> Enum.filter(&(is_map(&1) and &1["url"]))
    |> Enum.map(fn row ->
      publisher = if row["domain"], do: String.replace(to_string(row["domain"]), ~r/^www\./, ""), else: publisher_from(row["url"])
      item(row["url"], row["title"], publisher, row["timestamp"] || row["time_published"])
    end)
  end

  defp item(url, title, publisher, published) do
    when_at =
      case published && DateTime.from_iso8601(to_string(published)) do
        {:ok, dt, _} -> dt
        _ -> DateTime.utc_now()
      end

    %{
      id: :crypto.hash(:sha, to_string(url)) |> Base.encode16(case: :lower) |> String.slice(0, 16),
      title: String.trim(to_string(title || "")),
      url: to_string(url || ""),
      source: publisher || "Unknown",
      published: DateTime.to_iso8601(when_at),
      summary: ""
    }
  end

  def publisher_from(url) do
    case URI.parse(to_string(url)) do
      %URI{host: host} when is_binary(host) -> String.replace(host, ~r/^www\./, "")
      _ -> "Unknown"
    end
  end

  defp dedupe(items) do
    items
    |> Enum.reduce({[], MapSet.new()}, fn entry, {kept, seen} ->
      if entry.url == "" or entry.title == "" or MapSet.member?(seen, entry.url),
        do: {kept, seen},
        else: {[entry | kept], MapSet.put(seen, entry.url)}
    end)
    |> elem(0)
    |> Enum.sort_by(& &1.published, :desc)
  end

  @doc "Newly found items win, older ones retained so mailed links keep resolving."
  def merge_items(existing, fresh, limit \\ 60) do
    existing = if is_list(existing), do: Enum.map(existing, &atomise/1), else: []

    (fresh ++ existing)
    |> Enum.filter(& &1[:id])
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.published, :desc)
    |> Enum.take(limit)
  end

  defp atomise(%{} = map), do: Map.new(map, fn {k, v} -> {if(is_binary(k), do: String.to_atom(k), else: k), v} end)
end
