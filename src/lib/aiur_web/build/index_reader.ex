defmodule AiurWeb.Build.IndexReader do
  @moduledoc false
  alias Aiur.BuildOrder.Index
  alias AiurWeb.Build.{Freshness, NowRows, PlannedRows}
  alias AiurWeb.OperatorControlCenter.PayloadLoader

  @spec read(MapSet.t() | :all, map(), keyword()) :: map()
  def read(dirty, previous, opts) do
    core = Index.read_core_parts(dirty, opts)
    parts = Map.merge(previous, core)

    repo =
      case parts[:repository] do
        {:ok, repo} -> repo
        _ -> nil
      end

    now =
      read_part(:now, dirty, parts, fn -> read_now(repo, opts) end)

    parts = Map.put(parts, :now, now)
    active = MapSet.new(producer_rows(now), & &1.num)
    context = Index.planning_context(parts, active)

    planned =
      read_part(:planned, dirty, parts, fn ->
        PlannedRows.build(parts[:queue], context.history_snapshot, active: active, todo_label: context.todo_label)
      end)

    nq = read_part(:not_queued, dirty, parts, fn -> context.not_queued end)
    parts |> Map.put(:planned, planned) |> Map.put(:not_queued, nq)
  end

  defp read_part(key, dirty, previous, fun) do
    if dirty == :all or MapSet.member?(dirty, key), do: Index.safe_read(key, fun), else: previous[key]
  end

  defp read_now(repo, opts) do
    units_fun = Keyword.get(opts, :units_fun, fn -> PayloadLoader.load(:cached).units end)
    units_now = NowRows.build(units_fun.(), repository: repo)

    if map_size(units_now.rows) > 0 do
      units_now
    else
      snapshot_fun = Keyword.get(opts, :running_rows_fun, &Freshness.read_running_rows/1)

      case snapshot_fun.(opts) do
        {:ok, %{statuses: statuses, running: running}} when is_list(statuses) and is_list(running) ->
          rows = fleet_rows(statuses, running)
          NowRows.build(%{status: :ready, snapshot: %{rows: rows}}, repository: repo)

        {:error, :timeout} ->
          {:error, :running_snapshot_timeout}

        {:error, _unavailable} ->
          {:error, :running_snapshot_unavailable}
      end
    end
  end

  defp fleet_rows(statuses, running) do
    running_by_identifier = Map.new(running, &{Map.get(&1, :identifier), &1})

    Enum.map(statuses, fn status ->
      now_row(status, Map.get(running_by_identifier, Map.get(status, :identifier), %{}))
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp producer_rows(%{rows: rows}) when is_map(rows), do: Map.values(rows)
  defp producer_rows(_), do: []

  defp now_row(%{identifier: _identifier, state: :running} = summary, running), do: now_row(summary, running, :running)
  defp now_row(%{identifier: _identifier, work_state: :retrying} = summary, running), do: now_row(summary, running, :retrying)

  defp now_row(%{identifier: _identifier, state: :paused, session_id: session} = summary, running) when is_binary(session),
    do: now_row(summary, running, :running)

  defp now_row(_summary, _running), do: nil

  defp now_row(summary, running, bucket) do
    identity = Map.get(summary, :tracker_identity)
    waiting = Map.get(summary, :waiting_reason)
    summary = Map.merge(summary, Map.take(running, [:started_at, :agent_family, :backend, :resolved_model, :effort, :progress_percent, :progress_freshness]))

    %{
      identity: identity,
      runtime: %{bucket: bucket, work_state: Map.get(summary, :work_state, :working)},
      reasons: %{waiting: waiting, pause: Map.get(summary, :pause_reason)},
      timestamps: %{started_at: Map.get(summary, :started_at)},
      effort: Map.get(summary, :effort),
      open_command_count: Map.get(summary, :open_decision_count, 0),
      agent_family: Map.get(summary, :agent_family),
      backend: Map.get(summary, :backend),
      progress_percent: Map.get(summary, :progress_percent),
      progress_freshness: Map.get(summary, :progress_freshness)
    }
  end
end
