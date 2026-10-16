defmodule AiurWeb.Build.IndexReader do
  @moduledoc false
  alias Aiur.BuildOrder.Index
  alias AiurWeb.Build.{NowRows, PlannedRows}
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
      read_part(:now, dirty, parts, fn ->
        loader = Keyword.get(opts, :payload_loader, PayloadLoader)
        NowRows.build(loader.load(:cached).units, repository: repo)
      end)

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

  defp producer_rows(%{rows: rows}) when is_map(rows), do: Map.values(rows)
  defp producer_rows(_), do: []
end
