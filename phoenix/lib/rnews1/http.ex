defmodule Rnews1.HTTP do
  @moduledoc """
  Every outbound request goes through here so tests can stub the network with
  `Req.Test` (config :rnews1, :req_options, plug: {Req.Test, Rnews1.HTTP}).
  """
  def new(opts \\ []) do
    Req.new(Keyword.merge(Application.get_env(:rnews1, :req_options, []), opts))
  end

  def get(url, opts \\ []), do: Req.get(new(opts), url: url)
  def post(url, opts \\ []), do: Req.post(new(opts), url: url)
end
