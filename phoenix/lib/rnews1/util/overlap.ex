defmodule Rnews1.Util.Overlap do
  @moduledoc """
  How much verbatim text two passages share.

  This is the objective check on whether a "rewrite" actually rewrote
  anything. Words are compared with punctuation and case stripped; bare
  numbers do not count towards a run, because facts are not copyrightable and
  there is no way to report a net loss of $359.5 million in different numbers.
  """

  @doc """
  Twelve consecutive words of prose is the threshold. Below it you get false
  positives from stock phrasing; above it real lifting slips through.
  """
  def verbatim_limit, do: 12

  def words(value) do
    (value || "")
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
  end

  defp number?(word), do: Regex.match?(~r/^\d+$/, word)

  def prose_length(phrase) do
    phrase |> String.split(" ", trim: true) |> Enum.reject(&number?/1) |> length()
  end

  @doc """
  The longest run of consecutive words that appears in both, capped at `limit`
  so a pathological pair cannot make this expensive. Returns the run itself,
  which is what makes a rejection legible in a log, and `prose` — the length
  ignoring figures, which is what the threshold is measured against.
  """
  def longest_shared_run(source, candidate, limit \\ 40) do
    a = words(source)
    b = words(candidate)

    if a == [] or b == [] do
      %{length: 0, prose: 0, phrase: ""}
    else
      top = Enum.min([limit, length(a), length(b)])
      grow(a, b, 5, top, %{length: 0, prose: 0, phrase: ""})
    end
  end

  # Index the source by n-gram, growing n only while matches keep being found.
  # Starting at 5 skips the noise floor.
  defp grow(_a, _b, n, top, best) when n > top, do: best

  defp grow(a, b, n, top, best) do
    seen = a |> ngrams(n) |> MapSet.new()

    case b |> ngrams(n) |> Enum.find(&MapSet.member?(seen, &1)) do
      nil -> best
      found -> grow(a, b, n + 1, top, %{length: n, prose: prose_length(found), phrase: found})
    end
  end

  defp ngrams(list, n) do
    list |> Enum.chunk_every(n, 1, :discard) |> Enum.map(&Enum.join(&1, " "))
  end

  def too_close?(source, candidate, limit \\ verbatim_limit()) do
    longest_shared_run(source, candidate, limit * 2).prose >= limit
  end
end
