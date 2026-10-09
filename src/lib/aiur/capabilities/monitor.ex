defmodule Aiur.Capabilities.Monitor do
  @moduledoc "Periodically computes capabilities; all durable read state belongs to Table."
  use GenServer
  require Logger

  alias Aiur.Capabilities.Collector

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    send(self(), :tick)
    {:ok, %{opts: opts, warnings: MapSet.new(), timer: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    state = compute(state)
    timer = Process.send_after(self(), :tick, Keyword.get(state.opts, :tick_ms, 2_000))
    {:noreply, %{state | timer: timer}}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, compute(state)}

  defp compute(state) do
    {report, warnings} = Collector.collect(state.opts)
    for warning <- MapSet.difference(warnings, state.warnings), do: Logger.warning("capability_registry #{inspect(warning)}")
    table = Keyword.get(state.opts, :table, :aiur_capabilities)
    digest = :erlang.phash2(report.capabilities)
    revision = revision(table, digest)
    report = Map.merge(report, %{revision: revision, observed_at: DateTime.utc_now() |> DateTime.to_iso8601()})
    now = Keyword.get(state.opts, :now_fun, fn -> System.monotonic_time(:millisecond) end)
    :ets.insert(table, {:report, {report, now.(), digest}})
    %{state | warnings: warnings}
  end

  defp revision(table, digest) do
    case :ets.lookup(table, :report) do
      [{:report, {_report, _computed_at, ^digest}}] -> :ets.lookup_element(table, :revision, 2)
      _changed -> :ets.update_counter(table, :revision, 1, {:revision, 0})
    end
  end
end
