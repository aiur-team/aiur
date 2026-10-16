defmodule Aiur.Experiments.Auto.FeatureState do
  @moduledoc false

  @spec transition(map() | nil, map(), map(), DateTime.t()) :: {map(), [atom()]}
  def transition(%{"phase" => phase} = state, _observation, _config, _now) when phase in ~w(cancelled skipped), do: {state, []}

  def transition(%{"phase" => "line_set"} = state, observation, _config, _now) do
    numbers = Enum.map(observation["members"], & &1["number"]) |> Enum.sort()
    if numbers -- state["member_numbers"] == [], do: {state, []}, else: {Map.put(state, "member_numbers", numbers), [:scope]}
  end

  def transition(nil, observation, config, now), do: discover(observation, config, now)
  def transition(%{"phase" => "not_an_epic"}, observation, config, now), do: discover(observation, config, now)

  def transition(state, observation, config, now) do
    state = Map.merge(state, exclusions(observation))

    cond do
      not observation["labelled"] -> {Map.put(state, "phase", "cancelled"), [:cancel]}
      all_excluded?(observation) -> {Map.put(state, "phase", "cancelled"), [:cancel]}
      true -> advance(state, observation, config, now)
    end
  end

  defp discover(observation, config, now) do
    if observation["labelled"] and observation["members"] != [] do
      arm(observation, config, now)
    else
      {%{"phase" => "not_an_epic"}, []}
    end
  end

  defp arm(observation, config, now) do
    first = List.first(merges(observation))
    anchor = if first, do: first["at"], else: iso(now)

    state = %{
      "phase" => "armed",
      "armed_at" => iso(now),
      "before_end" => anchor,
      "before_start" => iso(DateTime.add(time(anchor), -config.before_days * 86_400)),
      "first_merge" => first,
      "last_merge" => List.last(merges(observation)),
      "fingerprint" => fingerprint(observation),
      "changed_at" => iso(now),
      "baseline_coverage" => if(first, do: "partial", else: "complete"),
      "member_numbers" => Enum.map(observation["members"], & &1["number"]) |> Enum.sort(),
      "member_limit" => observation["member_limit"] || false,
      "cross_repo_excluded" => observation["cross_repo_excluded"] || []
    }

    {Map.merge(state, exclusions(observation)), [:arm]}
  end

  defp advance(state, observation, config, now) do
    ordered = merges(observation)
    first = state["first_merge"] || List.first(ordered)
    freeze? = is_nil(state["first_merge"]) and not is_nil(first)
    changed = fingerprint(observation)

    updated =
      state
      |> Map.put("member_numbers", Enum.map(observation["members"], & &1["number"]) |> Enum.sort())
      |> Map.put("first_merge", first)
      |> Map.put("last_merge", List.last(ordered) || state["last_merge"])

    updated = if changed == state["fingerprint"], do: updated, else: Map.merge(updated, %{"fingerprint" => changed, "changed_at" => iso(now)})
    updated = if freeze?, do: Map.merge(updated, %{"before_end" => first["at"], "before_start" => iso(DateTime.add(time(first["at"]), -config.before_days * 86_400))}), else: updated
    phase = phase(updated, observation, config, now)
    effects = if freeze?, do: [:freeze], else: []
    {Map.put(updated, "phase", phase), effects ++ if(phase == "awaiting_live", do: [:resolve_live], else: [])}
  end

  defp phase(state, observation, config, now) do
    cond do
      is_nil(state["last_merge"]) -> "armed"
      Enum.all?(observation["members"], &(&1["state"] == "closed")) and DateTime.diff(now, time(state["changed_at"])) >= config.feature_quiet_hours * 3_600 -> "awaiting_live"
      true -> "merging"
    end
  end

  defp exclusions(observation) do
    merged = Enum.map(observation["merges"], & &1["number"])
    completed = for member <- observation["members"], member["state"] == "closed" and member["state_reason"] == "completed" and member["number"] not in merged, do: member["number"]
    %{"excluded_completed" => completed, "cross_repo_excluded" => observation["cross_repo_excluded"] || [], "member_limit" => observation["member_limit"] || false}
  end

  defp all_excluded?(observation), do: observation["members"] != [] and observation["merges"] == [] and Enum.all?(observation["members"], &(&1["state"] == "closed"))
  defp merges(observation), do: Enum.sort_by(observation["merges"], & &1["at"])
  defp fingerprint(observation), do: Jason.encode!({observation["members"], observation["merges"]} |> Tuple.to_list())
  defp time(value), do: value |> DateTime.from_iso8601() |> elem(1)
  defp iso(value), do: DateTime.to_iso8601(value)
end
