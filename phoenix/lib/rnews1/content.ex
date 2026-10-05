defmodule Rnews1.Content do
  @moduledoc """
  Copy and layout from content.json: the brand, the archive's copy, and the
  briefing page's blocks. Re-read when the file changes, so editing copy is a
  save rather than a restart. Everything is optional and everything falls
  back: a malformed file logs and renders the defaults rather than failing a
  page someone is waiting for.
  """
  require Logger

  @file_name "content.json"

  def file, do: Path.join(File.cwd!(), @file_name)

  @colour ~r/^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i
  @margin ~r/^\d{1,3}(mm|cm|in|pt)$/

  def report_defaults do
    %{
      title: "Daily Newsletter",
      eyebrow: "{{company}}",
      footnote: "",
      labels: %{
        reportedBy: "Reported by",
        readStory: "Read the full story",
        alsoToday: "Also today",
        storiesToday: "stories today",
        preparedFor: "Prepared for",
        topics: "Following",
        whyThese: "Why these sections"
      },
      theme: %{accent: "#1a4fd6", ink: "#14181f", muted: "#5a6472", paper: "#ffffff"},
      print: %{pageSize: "A4", margin: "16mm"},
      blocks: [
        %{type: "masthead"},
        %{type: "stories", limit: 8, hero: true, columns: 2},
        %{type: "impact"},
        %{type: "footer"}
      ]
    }
  end

  def brand_defaults do
    %{
      name: "rnews1",
      tagline: "Real News, made for One.",
      description:
        "Real News, Made for One. RNews1 writes daily news from published reporting, and automated industry newsletters for companies."
    }
  end

  def archive_defaults do
    %{
      title: "Real News, Made for One",
      intro: "Every story here is written for one reader at a time.",
      sectionIntro: "{{section}} reporting, written for the person reading it."
    }
  end

  def report, do: load().report
  def brand, do: load().brand
  def archive, do: load().archive

  @doc "{{company}} and friends, substituted as plain text; the template escapes."
  def fill(template, values) do
    Regex.replace(~r/\{\{(\w+)\}\}/, to_string(template || ""), fn whole, key ->
      case Map.fetch(values, String.to_atom(key)) do
        {:ok, value} -> to_string(value)
        :error -> whole
      end
    end)
  end

  def reset_cache, do: :persistent_term.erase({__MODULE__, :cache})

  defp load do
    stamp =
      case File.stat(file()) do
        {:ok, %{mtime: mtime}} -> mtime
        _ -> nil
      end

    case :persistent_term.get({__MODULE__, :cache}, nil) do
      {^stamp, parsed} ->
        parsed

      _ ->
        parsed = parse_file()
        :persistent_term.put({__MODULE__, :cache}, {stamp, parsed})
        parsed
    end
  end

  defp parse_file do
    raw =
      case File.read(file()) do
        {:ok, text} ->
          case Jason.decode(text) do
            {:ok, map} when is_map(map) ->
              map

            {:error, error} ->
              Logger.error("content.json is not valid JSON, using defaults: #{inspect(error)}")
              %{}

            _ ->
              %{}
          end

        _ ->
          %{}
      end

    %{
      report: parse_report(raw["report"]),
      brand: parse_brand(raw["brand"]),
      archive: parse_archive(raw["archive"])
    }
  end

  defp parse_brand(value) do
    d = brand_defaults()

    %{
      name: str(value, "name", d.name, 60),
      tagline: str(value, "tagline", d.tagline, 120),
      description: str(value, "description", d.description, 300)
    }
  end

  defp parse_archive(value) do
    d = archive_defaults()

    %{
      title: str(value, "title", d.title, 120),
      intro: str(value, "intro", d.intro, 400),
      sectionIntro: str(value, "sectionIntro", d.sectionIntro, 400)
    }
  end

  defp parse_report(value) do
    d = report_defaults()
    value = if is_map(value), do: value, else: %{}
    labels = value["labels"] || %{}
    theme = value["theme"] || %{}
    print = value["print"] || %{}

    %{
      title: str(value, "title", d.title, 120),
      eyebrow: str(value, "eyebrow", d.eyebrow, 160),
      footnote: str(value, "footnote", d.footnote, 600),
      labels: Map.new(d.labels, fn {key, default} -> {key, str(labels, to_string(key), default, 60)} end),
      # Colours reach a <style> block, so they are validated as colours.
      theme:
        Map.new(d.theme, fn {key, default} ->
          {key, colour(theme[to_string(key)], default, "report.theme.#{key}")}
        end),
      print: %{
        pageSize: if(print["pageSize"] in ["A4", "Letter", "Legal"], do: print["pageSize"], else: d.print.pageSize),
        margin: if(is_binary(print["margin"]) and Regex.match?(@margin, print["margin"]), do: print["margin"], else: d.print.margin)
      },
      blocks: blocks(value["blocks"], d.blocks)
    }
  end

  defp blocks(list, default) when is_list(list) and list != [] do
    parsed = Enum.map(list, &block/1)

    if Enum.all?(parsed) do
      parsed
    else
      Logger.error("content.json is invalid at \"report.blocks\": unknown block type. Using defaults.")
      default
    end
  end

  defp blocks(_, default), do: default

  defp block(%{"type" => "masthead"}), do: %{type: "masthead"}
  defp block(%{"type" => "summary"}), do: %{type: "summary"}
  defp block(%{"type" => "impact"}), do: %{type: "impact"}
  defp block(%{"type" => "footer"}), do: %{type: "footer"}

  defp block(%{"type" => "stories"} = b) do
    %{
      type: "stories",
      limit: clamp_int(b["limit"], 8, 1, 50),
      hero: if(is_boolean(b["hero"]), do: b["hero"], else: true),
      columns: if(b["columns"] in [1, 2], do: b["columns"], else: 2)
    }
  end

  defp block(%{"type" => "note", "body" => body} = b) when is_binary(body) do
    %{type: "note", title: String.slice(b["title"] || "", 0, 120), body: String.slice(body, 0, 2000)}
  end

  defp block(_), do: nil

  defp str(map, key, default, max) when is_map(map) do
    case map[key] do
      value when is_binary(value) -> String.slice(value, 0, max)
      _ -> default
    end
  end

  defp str(_, _, default, _), do: default

  defp colour(value, default, where) do
    cond do
      is_binary(value) and Regex.match?(@colour, value) ->
        value

      is_binary(value) ->
        Logger.error("content.json is invalid at \"#{where}\": must be a hex colour. Using defaults.")
        default

      true ->
        default
    end
  end

  defp clamp_int(value, _default, min, max) when is_integer(value), do: value |> max(min) |> min(max)
  defp clamp_int(_, default, _, _), do: default
end
