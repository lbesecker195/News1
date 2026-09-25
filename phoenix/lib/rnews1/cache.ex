defmodule Rnews1.Cache do
  @moduledoc "A public ETS table for small TTL caches: robots.txt, the PayPal token."
  use GenServer

  @table :rnews1_cache

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, until}] ->
        if until > System.monotonic_time(:millisecond), do: {:ok, value}, else: :miss

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  def put(key, value, ttl_ms) do
    :ets.insert(@table, {key, value, System.monotonic_time(:millisecond) + ttl_ms})
    value
  rescue
    ArgumentError -> value
  end

  @doc "Only for tests: robots rules and tokens must not leak between cases."
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def delete(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
