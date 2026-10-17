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
        total == 0 -> :empty
        resolved == 0 -> :unresolved
        resolved < total -> :partial
        true -> :resolved
      end

    %{completed: if(resolved > 0, do: completed), resolved: resolved, total: total, percent: if(resolved > 0, do: div(completed * 100, total)), resolution: resolution}
  end

  @doc "Why a lane has no percent, so the panel never shows a bare \"Unresolved\" (#4819)."
  @spec reasons(map(), [map()], map(), map() | nil) :: [atom()]
  def reasons(_queue, _items, %{percent: percent}, _build_order) when is_number(percent), do: []

  def reasons(%{kind: :build_order}, _items, _progress, %{source: source}) do
    case source do
      %{reasons: [_ | _] = reasons} -> reasons
      %{freshness: :stale} -> [:projection_stale]
      %{freshness: :current} -> [:members_unresolved]
      _ -> [:unknown]
    end
  end

  def reasons(%{kind: :build_order}, _items, _progress, _build_order), do: [:unknown]
  def reasons(_queue, [], _progress, _build_order), do: [:no_members]
  def reasons(_queue, _items, %{resolution: :unknown}, _build_order), do: [:progress_unavailable]
  def reasons(_queue, _items, _progress, _build_order), do: [:members_unresolved]

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

      facts = for row <- model.queues, fact = fact(queues[row.queue_id], row.items, source), fact != nil, do: fact
      publish_facts(facts)
    else
      :ok
    end
  end

  defp publish_facts(facts) do
    Enum.reduce_while(facts, :ok, fn fact, :ok ->
      case put_fact(fact) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
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
