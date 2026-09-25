defmodule Rnews1.Util.HTML do
  @moduledoc "Escaping and the one URL guard every href from outside goes through."

  def escape(nil), do: ""

  def escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  @doc """
  Article URLs come from third-party feeds and are rendered into href
  attributes, so anything that is not plain http(s) is dropped rather than
  passed through (javascript:, data:, and friends).
  """
  def safe_url(value) do
    case URI.new(to_string(value || "")) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        URI.to_string(uri)

      _ ->
        "#"
    end
  end
end
