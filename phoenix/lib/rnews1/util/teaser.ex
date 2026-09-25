defmodule Rnews1.Util.Teaser do
  @moduledoc """
  The one-line teaser under a headline: the first sentence of the standfirst,
  ending in an ellipsis so it reads as an opening rather than a summary.
  """

  # A sentence ends at . ! or ? when the character before it is ordinary prose
  # (so "U.S." and "Inc." mid-sentence are left alone) and what follows starts a
  # new sentence or is the end of the text.
  @sentence_end ~r/^(.*?[a-z0-9\)\]”"'’][.!?…]+)(?=\s+["“‘(\[]?[A-Z0-9]|\s*$)/su
  @trailing ~r/[.!?…\s]+$/u

  def first_sentence(text, max \\ 120) do
    clean = (text || "") |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()

    if clean == "" do
      ""
    else
      sentence =
        case Regex.run(@sentence_end, clean) do
          [_, first | _] -> first
          _ -> clean
        end
        |> String.replace(@trailing, "")

      sentence =
        if String.length(sentence) > max do
          cut = sentence |> String.slice(0, max + 1) |> last_space()

          sentence
          |> String.slice(0, if(cut > max / 2, do: cut, else: max))
          |> String.replace(~r/[,;:\s]+$/u, "")
        else
          sentence
        end

      sentence <> "…"
    end
  end

  defp last_space(text) do
    case :binary.matches(text, " ") do
      [] -> -1
      matches -> matches |> List.last() |> elem(0) |> then(&String.length(binary_part(text, 0, &1)))
    end
  end
end
