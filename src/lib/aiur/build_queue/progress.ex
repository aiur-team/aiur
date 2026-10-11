defmodule Aiur.BuildQueue.Progress do
  @moduledoc "Shared list progress calculation and reconciliation fact producer."
  require Logger
  alias Aiur.BuildProgress
  alias Aiur.BuildQueue.ReadModel

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(BuildProgress) and GenServer.whereis(BuildProgress) != nil

  @spec summary([map()], boolean()) :: map()
  def summary(items, available \\ available?()) do
    if available, do: counts(items), else: unknown()
  end

  defp counts(items) do
    active = Enum.reject(items, &(&1.state == :removed))
    total = length(active)
    completed = Enum.count(active, &(&1.state == :completed))
    resolved = Enum.count(active, &(&1.state != :unknown))

    resolution =
      cond do
        total == 0 -> :unresolved
        resolved == 0 -> :unresolved
        resolved < total -> :partial
        true -> :resolved
      end

    %{completed: if(resolved > 0, do: completed), resolved: resolved, total: total, percent: if(resolved > 0, do: div(completed * 100, total)), resolution: resolution}
  end

  @spec fact(map(), [map()], map()) :: map() | nil
  def fact(%{kind: :build_order}, _items, _source), do: nil

  def fact(queue, items, source) do
    progress = summary(items)

    if progress.total not in [nil, 0] do
      Map.merge(progress, %{scope: {:queue, queue.id}, generation: queue.generation, freshness: source.freshness, observed_at: source.observed_at})
    end
  end

  @spec reconcile(map()) :: map()
  def reconcile(state) do
    case publish(Map.put(state, :progress_unavailable, false)) do
      :ok ->
        Map.put(state, :progress_unavailable, false)

      {:error, reason} ->
        reasons = Map.get(state, :progress_errors, MapSet.new())
        unless MapSet.member?(reasons, reason), do: Logger.warning("Build queue progress publication failed: #{inspect(reason)}")
        Map.merge(state, %{progress_unavailable: true, progress_errors: MapSet.put(reasons, reason)})
    end
  end

  @spec publish(map()) :: :ok | {:error, term()}
  def publish(state) do
    if available?() do
      model = ReadModel.build(state)
      source = model.sources["tracker_observation"]
      source = %{source | observed_at: source.observed_at || model.snapshot.captured_at}
      queues = Map.new(state.document.queues, &{&1.id, &1})

      Enum.reduce_while(model.queues, :ok, fn row, :ok ->
        case fact(queues[row.queue_id], row.items, source) do
          nil ->
            {:cont, :ok}

          fact ->
            case put_fact(fact) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
        end
      end)
    else
      :ok
    end
  end

  defp put_fact(fact) do
    BuildProgress.put_fact(fact)
  rescue
    error -> {:error, {:exception, error.__struct__, Exception.message(error)}}
  catch
    :exit, {reason, {GenServer, :call, _}} -> {:error, {:exit, reason}}
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp unknown, do: %{completed: nil, resolved: nil, total: nil, percent: nil, resolution: :unknown}
end
