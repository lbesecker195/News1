defmodule Rnews1.Util.Languages do
  @moduledoc """
  The twelve languages the archive publishes in.

  Names are endonyms — what each language calls itself — because a reader
  scanning for their own language recognises "Español" instantly and "Spanish"
  only if they already read English. `dir` matters more than it looks: Arabic
  and Urdu are right-to-left.
  """

  @names %{
    "ar" => %{name: "العربية", english: "Arabic", dir: "rtl"},
    "bn" => %{name: "বাংলা", english: "Bengali", dir: "ltr"},
    "en" => %{name: "English", english: "English", dir: "ltr"},
    "es" => %{name: "Español", english: "Spanish", dir: "ltr"},
    "fr" => %{name: "Français", english: "French", dir: "ltr"},
    "hi" => %{name: "हिन्दी", english: "Hindi", dir: "ltr"},
    "it" => %{name: "Italiano", english: "Italian", dir: "ltr"},
    "la" => %{name: "Latina", english: "Latin", dir: "ltr"},
    "pt" => %{name: "Português", english: "Portuguese", dir: "ltr"},
    "ru" => %{name: "Русский", english: "Russian", dir: "ltr"},
    "ur" => %{name: "اردو", english: "Urdu", dir: "rtl"},
    "zh" => %{name: "中文", english: "Chinese", dir: "ltr"}
  }

  @codes ~w(ar bn en es fr hi it la pt ru ur zh)

  def names, do: @names
  def codes, do: @codes
  def language?(code), do: code in @codes

  def name(code), do: get_in(@names, [code, :name]) || String.upcase(to_string(code))
  def english(code), do: get_in(@names, [code, :english]) || String.upcase(to_string(code))
  def direction(code), do: get_in(@names, [code, :dir]) || "ltr"
end
