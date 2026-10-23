defmodule Aiur.BuildQueue.LastRead do
  @moduledoc """
  The last read model the queue server served, so a timed-out read shows held data (#5818).

  A busy server is not an unreadable store: callers that time out get this model
  with every source marked stale and the read's age, instead of an empty
  `store_unavailable` view the sweep's own read contradicts.
  """

  @table :aiur_build_queue_last_read

  @doc "Records `model` for the calling server process; the server owns the table."
  @spec put(map()) :: true
  def put(model) do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.insert(@table, {self(), model})
  end

  @doc "Returns the last model `server` served, aged to `now` (ms), or `:none`."
  @spec carry(GenServer.server(), integer()) :: {:ok, map()} | :none
  def carry(server, now) do
    with pid when is_pid(pid) <- GenServer.whereis(server),
         [{^pid, model}] <- :ets.lookup(@table, pid) do
      {:ok, stale(model, now)}
    else
      _ -> :none
    end
  rescue
    ArgumentError -> :none
  end

  defp stale(model, now) do
    read_age = max(now - DateTime.to_unix(model.snapshot.captured_at, :millisecond), 0)

    %{
      model
      | snapshot: Map.put(model.snapshot, :carried_age_ms, read_age),
        sources: Map.new(model.sources, fn {name, source} -> {name, stale_source(source, now)} end)
    }
  end

  defp stale_source(%{observed_at: %DateTime{} = at} = source, now),
    do: %{source | age_ms: max(now - DateTime.to_unix(at, :millisecond), 0), freshness: :stale, reasons: source.reasons ++ [:read_timeout]}

  defp stale_source(source, _now), do: %{source | reasons: source.reasons ++ [:read_timeout]}
end
