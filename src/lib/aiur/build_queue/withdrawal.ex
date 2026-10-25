defmodule Aiur.BuildQueue.Withdrawal do
  @moduledoc false
  require Logger
  alias Aiur.BuildQueue.{Hints, Planner}

  @spec prepare(Planner.Input.t(), module()) :: {Planner.Input.t(), [Planner.action()]}
  def prepare(input, probe) do
    holds = recover_holds(input)
    input = %{input | opts: Keyword.put(input.opts, :withdrawal_holds, holds)}
    {_, actions} = Planner.plan(input)
    begins = for {:begin_withdraw, _} = action <- actions, do: action
    holds = Enum.reduce(begins, Keyword.fetch!(input.opts, :withdrawal_holds), fn {_, id}, holds -> MapSet.put(holds, id) end)
    for id <- holds, do: :ets.insert(Hints.table_name(), {id, Hints.sort_key(id), true})
    claims = probe.status(Enum.map(input.items, & &1.issue_id))
    claims = normalize(claims, holds)
    {%{input | claims: claims, opts: Keyword.put(input.opts, :withdrawal_holds, holds)}, begins}
  end

  defp recover_holds(input) do
    recovered =
      for item <- input.items,
          item.promoted_at != nil,
          intent <- input.intents,
          intent.issue_id == item.issue_id and intent.action == :withdraw and intent.outcome in [nil, :ok],
          observation = input.observations[item.issue_id],
          observation != nil,
          intent.recorded_at_ms >= DateTime.to_unix(item.promoted_at, :millisecond),
          intent.recorded_at_ms <= observation.observed_at_ms,
          MapSet.new(intent.target_labels) == MapSet.new(observation.labels),
          do: item.issue_id

    MapSet.union(Keyword.fetch!(input.opts, :withdrawal_holds), MapSet.new(recovered))
  end

  defp normalize(claims, holds) when is_map(claims) do
    Map.new(claims, fn
      {id, {:declined, _} = claim} -> {id, if(MapSet.member?(holds, id), do: :unclaimed, else: claim)}
      pair -> pair
    end)
  end

  defp normalize(claims, _holds), do: claims

  @spec ages(MapSet.t(String.t()), map(), integer(), pos_integer()) :: map()
  def ages(holds, previous, now, interval_seconds) do
    Map.new(holds, fn id ->
      since = Map.get(previous, id, now)

      if now - since >= 3 * interval_seconds * 1_000 do
        Logger.warning("Build queue withdrawal held for #{id}: no confirmed release; retaining dispatch hold")
        {id, now}
      else
        {id, since}
      end
    end)
  end
end
