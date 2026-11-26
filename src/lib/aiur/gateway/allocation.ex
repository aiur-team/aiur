defmodule Aiur.Gateway.Allocation do
  @moduledoc """
  Pure slot allocation across work groups (MPG-401). Walks the groups in priority
  order and gives each as many new starts as it can use, up to its own and its
  project's hard maximum. Slots a group cannot use fall through to the next one.
  Nothing running is ever stopped: grants are new starts only. No I/O, no clock.
  """

  @type project_id :: String.t()
  @type group :: {project_id(), String.t() | :none}
  @type demand :: %{ready: non_neg_integer(), promoted: non_neg_integer()}

  @spec allocate(non_neg_integer(), %{optional(group()) => demand()}, [group()], map(), %{optional(group()) => non_neg_integer()}) ::
          %{optional(group()) => pos_integer()}
  def allocate(capacity, demands, priorities, limits, running) do
    unlisted = demands |> Map.keys() |> Enum.reject(&(&1 in priorities)) |> Enum.sort()
    order = priorities ++ unlisted
    free = max(capacity - Enum.sum(Map.values(running)), 0)
    {grants, free} = pass(order, &promoted/2, demands, limits, running, {%{}, free})
    {grants, _free} = pass(order, &ready/2, demands, limits, running, {grants, free})
    grants
  end

  defp promoted(d, _granted), do: min(d.promoted, d.ready)
  defp ready(d, granted), do: d.ready - granted

  defp pass(order, want_fun, demands, limits, running, acc) do
    Enum.reduce(order, acc, fn {project, _} = group, {grants, free} ->
      d = Map.get(demands, group, %{ready: 0, promoted: 0})
      granted = Map.get(grants, group, 0)
      used_group = Map.get(running, group, 0) + granted
      used_project = used(running, project) + used(grants, project)

      n =
        Enum.min([
          want_fun.(d, granted),
          free,
          headroom(limits, group, used_group),
          headroom(limits, project, used_project)
        ])

      if n > 0, do: {Map.put(grants, group, granted + n), free - n}, else: {grants, free}
    end)
  end

  defp used(counts, project), do: for({{^project, _}, n} <- counts, reduce: 0, do: (acc -> acc + n))

  # :infinity sorts above every integer, so Enum.min ignores a missing limit.
  defp headroom(limits, key, used) do
    case Map.fetch(limits, key) do
      {:ok, limit} -> max(limit - used, 0)
      :error -> :infinity
    end
  end
end
