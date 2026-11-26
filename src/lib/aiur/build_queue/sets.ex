defmodule Aiur.BuildQueue.Sets do
  @moduledoc "Queue set membership and observation evidence for dispatch; no tracker reads."

  alias Aiur.BuildQueue.Settings

  @spec next_rank(map()) :: non_neg_integer()
  def next_rank(document), do: Enum.map(document.queues, & &1.rank) |> Enum.max(fn -> -1 end) |> Kernel.+(1)

  @spec snapshot(map(), [map()], Aiur.Config.Schema.t(), map() | nil) :: map()
  def snapshot(document, projections, settings, observations) do
    projected = Map.new(projections, &{&1.issue_id, &1})
    now = System.system_time(:millisecond)
    sets = Enum.map(document.queues, &set(&1, document.items, projected, observations, now)) |> Enum.sort_by(&{&1.rank, &1.id})
    members = Map.new(document.items, &{&1.issue_id, %{set_id: &1.queue_id, position: &1.position || 0}})
    %{sets: sets, members: members, max_age_ms: Settings.observation_max_age_ms(settings)}
  end

  defp set(queue, items, projected, observations, now) do
    items = Enum.filter(items, &(&1.queue_id == queue.id))
    states = Enum.map(items, &Map.get(projected, &1.issue_id, %{state: :unknown}))
    unfinished = Enum.any?(states, &(&1.state not in [:completed, :cancelled, :removed]))
    observed = if is_nil(observations), do: now, else: observed_at(items, observations)

    %{
      id: queue.id,
      rank: queue.rank,
      held: queue.held,
      unfinished: unfinished,
      active: Enum.any?(states, &(&1.state == :claimed)),
      unknown: Enum.any?(states, &(&1.state == :unknown)),
      observed_at_ms: observed
    }
  end

  defp observed_at(items, observations) do
    times = Enum.map(items, fn item -> if observations[item.issue_id], do: observations[item.issue_id].observed_at_ms end)
    if nil in times, do: nil, else: Enum.min(times, fn -> nil end)
  end
end
