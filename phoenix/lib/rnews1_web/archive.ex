defmodule Rnews1Web.Archive do
  @moduledoc "URL building for the archive: /{language}/{topic}/{slug}/{yyyy-mm-dd}."

  # Formatted by Postgres, never derived from a DateTime.
  def date_of(story), do: story[:date_slug]

  def path_for(story) do
    [story.language, URI.encode(String.downcase(to_string(story[:category] || "news"))), URI.encode(story.slug), date_of(story)]
    |> Enum.join("/")
  end

  def slug_path(row) do
    "#{URI.encode(String.downcase(to_string(row[:category] || "news")))}/#{URI.encode(row.slug)}/#{date_of(row)}"
  end
end
