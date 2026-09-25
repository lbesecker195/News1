defmodule Rnews1.Extract do
  @moduledoc """
  Fetching the article behind a headline: obeys robots.txt, identifies itself
  honestly, and never persists the publisher's text. Extraction degrades
  rather than fails.
  """
  require Logger
  alias Rnews1.{Cache, Env, HTTP}

  @fetch_timeout 15_000
  @robots_timeout 5_000
  @max_bytes 2_000_000
  @max_body_chars 8_000
  @min_useful_chars 400
  @robots_ttl 3_600_000

  def max_body_chars, do: @max_body_chars

  def agent, do: "Rnews1/1.0 (+#{Env.app_origin()}/about; newsletter summarisation)"

  # ---- robots.txt -------------------------------------------------------------

  def allowed?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = target when scheme in ["http", "https"] and is_binary(host) ->
        origin = "#{scheme}://#{host}#{if target.port not in [nil, 80, 443], do: ":#{target.port}", else: ""}"

        case robots_for(origin) do
          nil ->
            true

          rules ->
            path = "#{target.path || "/"}#{if target.query, do: "?" <> target.query, else: ""}"

            rules
            |> Enum.filter(fn rule -> rule.path != "" and String.starts_with?(path, rule.path) end)
            |> Enum.max_by(&String.length(&1.path), fn -> nil end)
            |> case do
              nil -> true
              rule -> rule.allow
            end
        end

      _ ->
        false
    end
  end

  defp robots_for(origin) do
    case Cache.get({:robots, origin}) do
      {:ok, rules} ->
        rules

      :miss ->
        rules =
          case HTTP.get("#{origin}/robots.txt", headers: headers(), receive_timeout: @robots_timeout, redirect: true) do
            {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) -> parse_robots(body)
            _ -> nil
          end

        Cache.put({:robots, origin}, rules, @robots_ttl)
    end
  rescue
    _ -> nil
  end

  def parse_robots(text) do
    {groups, _current} =
      text
      |> to_string()
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], nil}, fn raw, {groups, current} ->
        line = raw |> String.replace(~r/#.*$/, "") |> String.trim()

        if line == "" do
          {groups, current}
        else
          [field | rest] = String.split(line, ":")
          key = field |> String.trim() |> String.downcase()
          value = rest |> Enum.join(":") |> String.trim()

          case key do
            "user-agent" ->
              if is_nil(current) or current.rules != [] do
                group = %{agents: [String.downcase(value)], rules: []}
                {groups ++ [group], group}
              else
                updated = %{current | agents: current.agents ++ [String.downcase(value)]}
                {List.replace_at(groups, -1, updated), updated}
              end

            "disallow" when not is_nil(current) ->
              updated = %{current | rules: current.rules ++ [%{path: value, allow: false}]}
              {List.replace_at(groups, -1, updated), updated}

            "allow" when not is_nil(current) ->
              updated = %{current | rules: current.rules ++ [%{path: value, allow: true}]}
              {List.replace_at(groups, -1, updated), updated}

            _ ->
              {groups, current}
          end
        end
      end)

    ours = Enum.find(groups, fn g -> Enum.any?(g.agents, &String.contains?(&1, "rnews1")) end)
    wildcard = Enum.find(groups, fn g -> "*" in g.agents end)

    case ours || wildcard do
      nil -> nil
      group -> group.rules
    end
  end

  # ---- fetching -----------------------------------------------------------------

  defp headers do
    [{"user-agent", agent()}, {"accept", "text/html,application/xhtml+xml"}, {"accept-language", "en"}]
  end

  @doc "Google News links are redirects; the older format carries the target base64 in the path."
  def decode_google_news_url(url) do
    with [_, encoded] <- Regex.run(~r/news\.google\.com\/rss\/articles\/([\w-]+)/, to_string(url)),
         {:ok, decoded} <- Base.url_decode64(encoded, padding: false),
         [found | _] <- Regex.run(~r/https?:\/\/[^\s\x00-\x1f"'<>]+/, decoded) do
      found |> String.replace(~r/[^\w\-.\/:?=&%~+#@]+$/, "") |> URI.parse() |> URI.to_string()
    else
      _ -> nil
    end
  end

  @doc "Returns %{url, text, method, chars} or nil. Never raises."
  def fetch_article(link) do
    case resolve(link) do
      nil ->
        nil

      %{url: url, html: html} ->
        cond do
          not allowed?(url) ->
            %{url: url, text: nil, method: "robots_denied", chars: 0}

          true ->
            case extract_article_text(html) do
              nil -> %{url: url, text: nil, method: "no_content", chars: 0}
              %{text: text, method: method} -> %{url: url, text: String.slice(text, 0, @max_body_chars), method: method, chars: String.length(text)}
            end
        end
    end
  rescue
    e ->
      Logger.warning("Article fetch failed: #{Exception.message(e)}")
      nil
  end

  defp resolve(link) do
    [link, decode_google_news_url(link)]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(fn attempt ->
      case follow(attempt, 5) do
        {:ok, final_url, %{status: status, headers: resp_headers, body: body}} when status in 200..299 ->
          type = resp_headers |> Map.get("content-type", []) |> List.first() || ""
          host = URI.parse(final_url).host || ""

          cond do
            not String.contains?(type, "html") -> nil
            Regex.match?(~r/(^|\.)news\.google\.com$/, host) -> nil
            not is_binary(body) or body == "" -> nil
            true -> %{url: final_url, html: binary_part(body, 0, min(byte_size(body), @max_bytes))}
          end

        _ ->
          nil
      end
    end)
  end

  # Redirects are followed by hand so the final URL is known: a link can land
  # anywhere, including back on our own site through an aggregator.
  defp follow(url, hops) when hops >= 0 do
    case HTTP.get(url, headers: headers(), receive_timeout: @fetch_timeout, redirect: false, decode_body: false) do
      {:ok, %{status: status, headers: resp_headers} = response} when status in [301, 302, 303, 307, 308] and hops > 0 ->
        case Map.get(resp_headers, "location") do
          [location | _] -> follow(URI.merge(url, location) |> URI.to_string(), hops - 1)
          _ -> {:ok, url, response}
        end

      {:ok, response} ->
        {:ok, url, response}

      {:error, _} = error ->
        error
    end
  end

  defp follow(_url, _), do: {:error, :too_many_redirects}

  # ---- extraction -------------------------------------------------------------

  def extract_article_text(html) do
    Enum.find_value([{"jsonld", &from_json_ld/1}, {"articletag", &from_article_tag/1}, {"paragraphs", &from_paragraphs/1}], fn {method, fun} ->
      case fun.(html) do
        text when is_binary(text) and byte_size(text) > 0 ->
          if String.length(text) >= @min_useful_chars, do: %{text: text, method: method}

        _ ->
          nil
      end
    end)
  end

  defp from_json_ld(html) do
    ~r/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/i
    |> Regex.scan(to_string(html))
    |> Enum.find_value(fn [_, raw] ->
      case Jason.decode(String.trim(raw)) do
        {:ok, parsed} -> parsed |> find_article_body(0) |> then(&if(&1, do: clean(&1)))
        _ -> nil
      end
    end)
  end

  defp find_article_body(_node, depth) when depth > 6, do: nil

  defp find_article_body(list, depth) when is_list(list), do: Enum.find_value(list, &find_article_body(&1, depth + 1))

  defp find_article_body(%{} = node, depth) do
    case node["articleBody"] do
      body when is_binary(body) and byte_size(body) > 200 ->
        body

      _ ->
        Enum.find_value(["@graph", "mainEntity", "mainEntityOfPage"], fn key ->
          find_article_body(node[key], depth + 1)
        end)
    end
  end

  defp find_article_body(_, _), do: nil

  defp from_article_tag(html) do
    case Regex.run(~r/<article\b[^>]*>([\s\S]*?)<\/article>/i, to_string(html)) do
      [_, inner] -> paragraphs_from(inner)
      _ -> nil
    end
  end

  defp from_paragraphs(html), do: paragraphs_from(to_string(html))

  defp paragraphs_from(fragment) do
    stripped =
      fragment
      |> String.replace(~r/<script[\s\S]*?<\/script>/i, " ")
      |> String.replace(~r/<style[\s\S]*?<\/style>/i, " ")
      |> String.replace(~r/<(nav|aside|footer|header|figure|form)[\s\S]*?<\/\1>/i, " ")

    paragraphs =
      ~r/<p\b[^>]*>([\s\S]*?)<\/p>/i
      |> Regex.scan(stripped)
      |> Enum.map(fn [_, inner] -> clean(inner) end)
      |> Enum.filter(&(String.length(&1) > 60))

    if paragraphs == [], do: nil, else: Enum.join(paragraphs, "\n\n")
  end

  @entities %{
    "amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'", "nbsp" => " ",
    "rsquo" => "’", "lsquo" => "‘", "ldquo" => "“", "rdquo" => "”", "mdash" => "—", "ndash" => "–", "hellip" => "…"
  }

  def clean(value) do
    value
    |> to_string()
    |> String.replace(~r/<[^>]*>/, " ")
    |> then(fn text ->
      Regex.replace(~r/&(#x[0-9a-f]+|#\d+|[a-z]+);/i, text, fn whole, entity ->
        key = String.downcase(entity)

        cond do
          Map.has_key?(@entities, key) -> @entities[key]
          String.starts_with?(key, "#x") -> key |> String.slice(2..-1//1) |> String.to_integer(16) |> codepoint(whole)
          String.starts_with?(key, "#") -> key |> String.slice(1..-1//1) |> String.to_integer() |> codepoint(whole)
          true -> whole
        end
      end)
    end)
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp codepoint(code, fallback) do
    <<code::utf8>>
  rescue
    _ -> fallback
  end
end
