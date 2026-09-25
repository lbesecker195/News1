defmodule Rnews1.Util.Slug do
  @moduledoc "URL slugs and subdomain labels from human text."

  @doc "The archive's slugs: shared across a translation set, unique across the archive."
  def slugify(text) do
    (text || "")
    |> to_string()
    |> :unicode.characters_to_nfkd_binary()
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
    |> String.downcase()
    |> String.replace(~r/['’]/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 70)
    |> String.trim_trailing("-")
  end

  @doc "A subdomain label from a company name: shorter, and no apostrophe rule."
  def label(text) do
    (text || "")
    |> to_string()
    |> String.downcase()
    |> :unicode.characters_to_nfkd_binary()
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> String.trim_trailing("-")
  end
end
