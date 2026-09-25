defmodule Rnews1.PDF.Starter do
  @moduledoc """
  Starts ChromicPDF next to the application supervisor instead of under it.

  Chrome is optional. When it dies, this process starts it again a few times;
  when it keeps dying, this process logs why and stops — temporarily, so the
  supervisor does not restart it — and `Rnews1.PDF.available?/0` is false
  from then on. Nothing else is touched.
  """
  use GenServer, restart: :temporary
  require Logger

  @attempts 3
  @pause_ms 1_000

  @doc """
  `opts` are ChromicPDF's. Two of our own: `:name` for this process, and
  `:start`, the function that starts the browser (ChromicPDF.start_link/1),
  which tests replace.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {start, opts} = Keyword.pop(opts, :start, &ChromicPDF.start_link/1)
    {:ok, %{opts: opts, start: start, attempts: 0}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: start_browser(state)

  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.warning("Chrome stopped (#{inspect(reason)}); starting it again.")
    Process.sleep(@pause_ms)
    start_browser(state)
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    case Process.whereis(ChromicPDF) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :shutdown)
    end
  catch
    :exit, _ -> :ok
  end

  defp start_browser(%{attempts: n} = state) when n >= @attempts do
    Logger.error(
      "Chrome failed to run #{n} times (#{inspect(state.opts[:chrome_executable])}); PDFs are unavailable until the service restarts."
    )

    {:stop, :normal, state}
  end

  defp start_browser(state) do
    state = %{state | attempts: state.attempts + 1}

    case state.start.(state.opts) do
      {:ok, _pid} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Chrome did not start (#{inspect(reason)}).")
        Process.sleep(@pause_ms)
        start_browser(state)
    end
  end
end
