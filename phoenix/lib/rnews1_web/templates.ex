defmodule Rnews1Web.Templates do
  @moduledoc """
  The documents that are not pages: the RSS feed, the sitemaps, and the brief
  landing page, which is a self-contained HTML file with its own CSS. Plain
  EEx — escaping is explicit with `e/1` — because these must round-trip
  through a PDF renderer and feed readers exactly as written.
  """
  require EEx

  def e(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @doc """
  What a customer's coverage is called on its public pages: "Robotics news".
  An industry typed as "Fashion News" already says it, and gets no second
  "news"; a blank one is just "news".
  """
  def news_label(industry) do
    case industry |> to_string() |> String.trim() do
      "" -> "news"
      industry -> if String.match?(industry, ~r/\bnews$/i), do: industry, else: "#{industry} news"
    end
  end

  EEx.function_from_file(:def, :rss, Path.join(__DIR__, "templates/rss.xml.eex"), [:assigns])
  EEx.function_from_file(:def, :sitemap, Path.join(__DIR__, "templates/sitemap.xml.eex"), [:assigns], trim: true)
  EEx.function_from_file(:def, :sitemap_index, Path.join(__DIR__, "templates/sitemap_index.xml.eex"), [:assigns], trim: true)
end

defmodule Rnews1Web.ReportHTML do
  @moduledoc "The brief landing page — hero card, clickable headlines, one printed sheet."
  require EEx
  import Rnews1Web.Templates, only: [e: 1]

  EEx.function_from_file(:def, :render_page, Path.join(__DIR__, "templates/report.html.eex"), [:assigns])
end
