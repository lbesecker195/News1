defmodule Rnews1Web.RateLimit do
  @moduledoc """
  Fixed-window counters in ETS, per process. Running more than one node
  multiplies every limit by the number of nodes; put a shared store in front
  before scaling out.
  """
  use GenServer

  @table :rnews1_rate_limits

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @doc "Increments and returns {:ok, remaining} or {:limited, retry_after_seconds}."
  def hit(name, key, window_ms, limit) do
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    counter = {name, key, window}
    count = :ets.update_counter(@table, counter, {2, 1}, {counter, 0, now + window_ms})

    if count > limit do
      {:limited, max(1, div((window + 1) * window_ms - now, 1000))}
    else
      {:ok, limit - count}
    end
  rescue
    ArgumentError -> {:ok, limit}
  end

  @doc "Only for tests: every test in a file shares one address."
  def reset_all do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, 60_000)
end

defmodule Rnews1Web.Plugs.RateLimit do
  @moduledoc """
  The limits the Node app carried, by name:

    login             5 / hour   — sends mail to whatever address was typed
    login_complete   30 / hour   — following a link; loose on purpose
    api              60 / minute
    invite           20 / hour
    public_feed     120 / minute
    admin_login      10 / 15 min — a password form
    password         10 / 15 min — password sign-in attempts
    beacon          120 / minute
  """
  @behaviour Plug
  import Plug.Conn

  @limits %{
    login: {3_600_000, 5},
    login_complete: {3_600_000, 30},
    api: {60_000, 60},
    invite: {3_600_000, 20},
    public_feed: {60_000, 120},
    admin_login: {900_000, 10},
    password: {900_000, 10},
    beacon: {60_000, 120}
  }

  def init(name) when is_atom(name), do: name

  def call(conn, name) do
    {window, limit} = Map.fetch!(@limits, name)
    key = conn.remote_ip |> :inet.ntoa() |> to_string()

    case Rnews1Web.RateLimit.hit(name, key, window, limit) do
      {:ok, _} ->
        conn

      {:limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "Too many requests. Try again shortly."}))
        |> halt()
    end
  end
end
