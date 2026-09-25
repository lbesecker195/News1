defmodule Rnews1.Util.Markdown do
  @moduledoc """
  A small deterministic renderer for our own Markdown: headings, bold, italic,
  links, lists, blockquotes, paragraphs. Everything is escaped before any tag
  is added, so no source text can introduce markup.
  """
  alias Rnews1.Util.HTML

  def render(source) do
    (source || "")
    |> to_string()
    |> String.replace("\r\n", "\n")
    |> String.split(~r/\n{2,}/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("\n", &block/1)
  end

  defp block(block) do
    cond do
      match = Regex.run(~r/^(#{"#"}{1,6})\s+(.*)$/s, block) ->
        [_, hashes, text] = match
        # h1 is the page title; body headings start one level down.
        level = min(6, String.length(hashes) + 1)
        "<h#{level}>#{inline(String.trim(text))}</h#{level}>"

      Regex.match?(~r/^>\s/, block) ->
        quoted =
          block |> String.split("\n") |> Enum.map_join(" ", &String.replace(&1, ~r/^>\s?/, ""))

        "<blockquote><p>#{inline(quoted)}</p></blockquote>"

      true ->
        lines = String.split(block, "\n")

        cond do
          Enum.all?(lines, &Regex.match?(~r/^\s*[-*]\s+/, &1)) ->
            list(lines, ~r/^\s*[-*]\s+/, "ul")

          Enum.all?(lines, &Regex.match?(~r/^\s*\d+[.)]\s+/, &1)) ->
            list(lines, ~r/^\s*\d+[.)]\s+/, "ol")

          true ->
            "<p>#{inline(String.replace(block, "\n", " "))}</p>"
        end
    end
  end

  defp list(lines, marker, tag) do
    items = Enum.map_join(lines, "", &"<li>#{inline(String.replace(&1, marker, ""))}</li>")
    "<#{tag}>#{items}</#{tag}>"
  end

  # Escaping happens first, so anything in the source that looks like markup is
  # text by the time the inline patterns run.
  defp inline(text) do
    text
    |> HTML.escape()
    |> String.replace(~r/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/, "<a href=\"\\2\" rel=\"noopener noreferrer\">\\1</a>")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/(^|[^*])\*([^*\n]+)\*/, "\\1<em>\\2</em>")
    |> String.replace(~r/`([^`]+)`/, "<code>\\1</code>")
  end
end
