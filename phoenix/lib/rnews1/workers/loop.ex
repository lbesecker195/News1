defmodule Rnews1.Workers.Loop do
  @moduledoc """
  One background loop: a step, an interval, and whether to drain. Errors are
  logged and the loop continues — one bad topic must not stop delivery.
  """
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(opts) do
    state = %{name: opts[:name], step: opts[:step], interval: opts[:interval], drain: opts[:drain] || false}
    Process.send_after(self(), :tick, opts[:delay] || 1_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      if state.drain do
        # Bounded so a large backlog cannot starve everything else.
        Enum.reduce_while(1..100, :ok, fn _, _ -> if state.step.(), do: {:cont, :ok}, else: {:halt, :ok} end)
      else
        state.step.()
      end
    rescue
      e -> Logger.error("#{state.name} loop error: #{Exception.format(:error, e, __STACKTRACE__)}")
    end

    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end
end

defmodule Rnews1.Workers.Supervisor do
  @moduledoc "content → delivery → scheduler → maintenance, each its own loop."
  use Supervisor
  require Logger
  alias Rnews1.Worker

  def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    children = [
      Supervisor.child_spec({Rnews1.Workers.Loop, name: Rnews1.Workers.Content, step: &Worker.refresh_one_topic/0, interval: 30_000, drain: true, delay: 5_000}, id: :content),
      Supervisor.child_spec({Rnews1.Workers.Loop, name: Rnews1.Workers.Delivery, step: &Worker.deliver_one/0, interval: 2_000, drain: true, delay: 5_000}, id: :delivery),
      Supervisor.child_spec({Rnews1.Workers.Loop, name: Rnews1.Workers.Scheduler, step: fn -> Worker.schedule_digests() || Worker.schedule_editions() end, interval: 60_000, drain: true, delay: 10_000}, id: :scheduler),
      Supervisor.child_spec({Rnews1.Workers.Loop, name: Rnews1.Workers.Maintenance, step: &Worker.maintenance/0, interval: 600_000, drain: false, delay: 30_000}, id: :maintenance)
    ]

    Logger.info("Rnews1 worker loops started.")
    Supervisor.init(children, strategy: :one_for_one)
  end
end
