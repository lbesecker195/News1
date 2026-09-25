defmodule Rnews1.Util.ReadingTime do
  @moduledoc """
  Minutes to read a body of text. Two rates, because words are not comparable
  across writing systems: Latin script at 220 words a minute, CJK at 500
  characters.
  """
  @words_per_minute 220
  @cjk_per_minute 500
  @cjk ~r/[\x{3040}-\x{30FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}]/u

  def minutes(text) do
    source = (text || "") |> to_string() |> String.replace(~r/[#*`>_\[\]()]/, " ") |> String.trim()

    if source == "" do
      0
    else
      cjk = @cjk |> Regex.scan(source) |> length()
      words = source |> String.split(~r/\s+/, trim: true) |> length()
      minutes = if cjk > words, do: cjk / @cjk_per_minute, else: words / @words_per_minute
      max(1, round(minutes))
    end
  end

  @doc "Listing rows carry a body length rather than the body itself."
  def from_length(length), do: max(1, round((length || 0) / 5 / @words_per_minute))
end
