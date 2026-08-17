defmodule Aiur.CurrentRunProjections.SourceCollector do
  @moduledoc false

  alias Aiur.CurrentRunProjections.SourceAdapter

  @type t :: %{
          ref: reference(),
          mode: :full | :clock,
          keys: [atom()],
          tasks: %{atom() => pid()},
          results: map(),
          timer: reference(),
          waiters: [GenServer.from()],
          base_summary: map(),
          base_outcomes: map()
        }

  @spec start(pid(), map(), keyword()) :: t()
  def start(owner, readers, opts) do
    ref = make_ref()
    mode = Keyword.fetch!(opts, :mode)
    keys = if mode == :clock, do: [:run], else: SourceAdapter.keys()
    task_supervisor = Keyword.get(opts, :task_supervisor)

    tasks =
      Map.new(keys, fn key ->
        fun = Map.fetch!(readers, key)
        {key, start_task(task_supervisor, fn -> collect(owner, ref, key, fun) end)}
      end)

    timer =
      Process.send_after(owner, {:current_run_source_deadline, ref}, Keyword.fetch!(opts, :timeout_ms))

    %{
      ref: ref,
      mode: mode,
      keys: keys,
      tasks: tasks,
      results: %{},
      timer: timer,
      waiters: Keyword.get(opts, :waiters, []),
      base_summary: Keyword.fetch!(opts, :base_summary),
      base_outcomes: Keyword.fetch!(opts, :base_outcomes)
    }
  end

  @spec put_result(t(), atom(), term()) :: t()
  def put_result(refresh, key, result) do
    %{refresh | results: Map.put(refresh.results, key, result), tasks: Map.delete(refresh.tasks, key)}
  end

  @spec complete?(t()) :: boolean()
  def complete?(refresh), do: map_size(refresh.results) == length(refresh.keys)

  @spec expire(t()) :: t()
  def expire(refresh) do
    results =
      Enum.reduce(refresh.keys, refresh.results, fn key, results ->
        Map.put_new(results, key, {:error, :deadline})
      end)

    %{refresh | results: results}
  end

  @spec finish(t()) :: :ok
  def finish(refresh) do
    _ = Process.cancel_timer(refresh.timer)
    Enum.each(refresh.tasks, fn {_key, pid} -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    :ok
  end

  @spec reply_waiters(t() | [GenServer.from()]) :: :ok
  def reply_waiters(%{waiters: waiters}), do: reply_waiters(waiters)

  def reply_waiters(waiters) when is_list(waiters) do
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    :ok
  end

  @spec mark_refreshing(map()) :: map()
  def mark_refreshing(snapshot) when is_map(snapshot) do
    snapshot
    |> Map.update(:health, refreshing_health(), &refreshing_health/1)
    |> Map.update(:freshness, refreshing_freshness(), &refreshing_freshness/1)
    |> Map.update(:sources, %{refreshing?: true}, &Map.put(&1, :refreshing?, true))
    |> mark_outcome_refreshing()
  end

  defp collect(owner, ref, key, fun) do
    send(owner, {:current_run_source_result, ref, key, SourceAdapter.read(key, fun)})
  end

  defp start_task(nil, fun) do
    {:ok, pid} = Task.start(fun)
    pid
  end

  defp start_task(supervisor, fun) do
    case safe_supervised_start(supervisor, fun) do
      {:ok, pid} -> pid
      {:error, _reason} -> start_task(nil, fun)
    end
  end

  defp safe_supervised_start(supervisor, fun) do
    Task.Supervisor.start_child(supervisor, fun)
  catch
    :exit, _reason -> {:error, :supervisor_unavailable}
  end

  defp refreshing_health do
    %{status: :partial, reasons: [:source_refresh_in_progress]}
  end

  defp refreshing_health(health) when is_map(health) do
    status = if Map.get(health, :status) == :healthy, do: :partial, else: Map.get(health, :status, :partial)
    reasons = Enum.uniq(List.wrap(Map.get(health, :reasons)) ++ [:source_refresh_in_progress])
    %{health | status: status, reasons: reasons}
  end

  defp refreshing_health(_health), do: refreshing_health()
  defp refreshing_freshness, do: %{status: :stale, refreshing?: true}
  defp refreshing_freshness(freshness) when is_map(freshness), do: freshness |> Map.put(:status, :stale) |> Map.put(:refreshing?, true)
  defp refreshing_freshness(_freshness), do: refreshing_freshness()

  defp mark_outcome_refreshing(%{state: state} = snapshot) when state in [:healthy, :healthy_empty] do
    snapshot |> Map.put(:state, :stale) |> Map.put(:completeness, :partial)
  end

  defp mark_outcome_refreshing(snapshot), do: snapshot
end
