defmodule Aiur.DecisionMetrics.Writer.Persistence do
  @moduledoc "Batched append and compaction transitions for the Decision metrics writer."

  require Logger

  @spec queue(map(), map()) :: map()
  def queue(state, record) do
    %{state | pending: [record | state.pending], pending_count: state.pending_count + 1}
  end

  @spec schedule(map()) :: map()
  def schedule(%{flush_timer: nil, pending_count: count} = state) when count > 0 do
    %{state | flush_timer: Process.send_after(self(), :flush, state.flush_interval_ms)}
  end

  def schedule(state), do: state

  @spec cancel(map()) :: map()
  def cancel(%{flush_timer: nil} = state), do: state

  def cancel(state) do
    Process.cancel_timer(state.flush_timer)
    %{state | flush_timer: nil}
  end

  @spec flush(map()) :: {:ok | {:error, term()}, map()}
  def flush(state) do
    cond do
      state.force_compact? -> compact(state)
      state.pending_count == 0 -> {:ok, state}
      state.record_count + state.pending_count > state.record_limit -> compact(state)
      true -> append(state)
    end
  end

  defp append(state) do
    records = Enum.reverse(state.pending)

    case state.append_fun.(state.path, records) do
      :ok ->
        {:ok,
         %{
           state
           | pending: [],
             pending_count: 0,
             record_count: state.record_count + length(records),
             flush_timer: nil
         }}

      {:error, reason} ->
        write_failed(state, :append, reason)
    end
  end

  defp compact(state) do
    records = Map.values(state.records)

    case state.compact_fun.(state.path, records) do
      :ok ->
        {:ok,
         %{
           state
           | pending: [],
             pending_count: 0,
             record_count: length(records),
             force_compact?: false,
             flush_timer: nil
         }}

      {:error, reason} ->
        write_failed(state, :compact, reason)
    end
  end

  defp write_failed(state, operation, reason) do
    Logger.error("decision_metrics write_failed operation=#{operation} error=#{inspect(reason)}")

    {{:error, reason},
     %{
       state
       | pending: [],
         pending_count: 0,
         force_compact?: true,
         flush_timer: nil
     }}
  end
end
