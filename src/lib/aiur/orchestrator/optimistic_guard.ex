defmodule Aiur.Orchestrator.OptimisticGuard do
  @moduledoc "Pure failure policy for durable optimistic starts; observations must be freshly confirmed."

  @cause :optimistic_blocker_failed
  @trouble ~w(agent:error agent:paused agent:parked agent:todo)

  @spec decide([map()], map(), integer(), keyword()) :: [tuple()]
  def decide(records, observations, now_ms, opts \\ []) do
    records
    |> Enum.reject(&(&1["status"] == "closed"))
    |> Enum.flat_map(&decide_record(&1, observations, now_ms, opts))
  end

  defp decide_record(record, observations, now, opts) do
    results = Enum.map(record["blockers"], &inspect_blocker(record["ticket"], &1, observations[&1["id"]], now, opts))
    updates = Enum.flat_map(results, &elem(&1, 0))
    outcomes = Enum.map(results, &elem(&1, 1))
    updates ++ record_actions(record, outcomes, opts)
  end

  defp inspect_blocker(dep, blocker, observation, now, opts) do
    cond do
      blocker["park_complete"] == true ->
        {[], :held}

      blocker["park_cause"] && blocker["park_complete"] != true ->
        {[], {:failed, blocker["id"], blocker["park_cause"]}}

      fresh?(observation, now, opts) ->
        classify_observation(dep, blocker, observation, now, opts)

      true ->
        {[], :unknown}
    end
  end

  defp fresh?(%{confirmed?: true, observed_at_ms: at}, now, opts) when is_integer(at),
    do: at <= now and now - at <= Keyword.get(opts, :observation_max_age_ms, 120_000)

  defp fresh?(_observation, _now, _opts), do: false

  defp classify_observation(dep, blocker, observation, now, opts) do
    edges = Map.get(observation, :edges, %{})

    edge_present =
      case edges[dep] do
        %MapSet{} = ids -> MapSet.member?(ids, blocker["id"])
        _ -> observation[:edge_present?]
      end

    observation = Map.put(observation, :edge_present?, edge_present)
    classification = classify(observation)
    observation_actions(dep, blocker, observation, classification, now, opts)
  end

  defp observation_actions(_dep, _blocker, _observation, :unknown, _now, _opts), do: {[], :unknown}

  defp observation_actions(dep, blocker, observation, classification, now, opts) do
    cause = suspect_cause(classification)
    since = suspect_since(blocker, observation, cause, now)
    facts = %{observed_at_ms: observation.observed_at_ms, suspect_since_ms: since, suspect_cause: cause}
    facts = Map.merge(facts, pr_facts(observation))
    facts = if classification == :healthy and blocker["failure_acknowledged"] == true, do: Map.put(facts, :failure_acknowledged, false), else: facts
    update = {:update_blocker, dep, blocker["id"], facts}
    outcome = if blocker["failure_acknowledged"] == true and classification != :healthy, do: :acknowledged, else: outcome(classification, blocker["id"], since, now, opts)
    {[update], outcome}
  end

  defp classify(%{edge_present?: false}), do: {:terminal, :edge_removed}
  defp classify(%{issue_open?: false, state_reason: reason}) when reason in [:not_planned, :duplicate, "not_planned", "duplicate"], do: {:terminal, reason}
  defp classify(%{issue_open?: false, state_reason: reason}) when reason in [:completed, "completed"], do: :healthy
  defp classify(%{pr_merged: true}), do: :healthy
  defp classify(%{pr_state: state}) when state in [:merged, "merged"], do: :healthy

  defp classify(observation) do
    trouble = Enum.find(Map.get(observation, :labels, []), &(&1 in @trouble))

    cond do
      observation[:pr_state] in [:closed, "closed"] and observation[:pr_merged] == false and observation[:any_open_pr?] == false -> {:suspect, :pr_closed_unmerged}
      trouble -> {:trouble, trouble_cause(trouble)}
      observation[:any_open_pr?] == true -> :healthy
      observation[:pr_state] in [:open, "open"] -> :healthy
      true -> :unknown
    end
  end

  defp trouble_cause("agent:error"), do: :agent_error
  defp trouble_cause("agent:paused"), do: :paused
  defp trouble_cause("agent:parked"), do: :parked
  defp trouble_cause("agent:todo"), do: :todo

  defp suspect_cause({kind, cause}) when kind in [:trouble, :suspect], do: to_string(cause)
  defp suspect_cause(_classification), do: nil
  defp suspect_since(_blocker, _observation, nil, _now), do: nil

  defp suspect_since(blocker, observation, cause, now) do
    if blocker["suspect_cause"] == cause and is_integer(blocker["suspect_since_ms"]) do
      if cause == "pr_closed_unmerged", do: max(blocker["suspect_since_ms"], observation[:pr_closed_at_ms] || blocker["suspect_since_ms"]), else: blocker["suspect_since_ms"]
    else
      if cause == "pr_closed_unmerged", do: Map.get(observation, :pr_closed_at_ms) || now, else: now
    end
  end

  defp pr_facts(%{any_open_pr?: true} = observation) do
    %{pr_number: observation[:pr_number], pr_state: "open", last_head_sha: observation[:pr_head_sha], last_head_ref: observation[:pr_head_ref]}
  end

  defp pr_facts(_observation), do: %{}

  defp outcome({:terminal, cause}, id, _since, _now, _opts), do: {:failed, id, cause}

  defp outcome({kind, cause}, id, since, now, opts) when kind in [:suspect, :trouble] do
    if now - since >= Keyword.get(opts, :grace_ms, 600_000) do
      if kind == :suspect, do: {:failed, id, cause}, else: {:trouble, id, cause}
    else
      :waiting
    end
  end

  defp outcome(classification, _id, _since, _now, _opts), do: classification

  defp record_actions(%{"status" => "parked"} = record, outcomes, _opts) do
    case Enum.find(outcomes, &match?({:failed, _, _}, &1)) do
      {:failed, blocker, cause} ->
        if Enum.any?(record["blockers"], &(&1["id"] == blocker and &1["park_complete"] == true)), do: [], else: [{:park, record["ticket"], blocker, cause}]

      _ ->
        []
    end
  end

  defp record_actions(record, outcomes, opts) do
    failure = Enum.find(outcomes, &match?({:failed, _, _}, &1))
    trouble = Enum.find(outcomes, &match?({:trouble, _, _}, &1))
    threshold = Keyword.get(opts, :churn_threshold, 3)
    churn? = record["blockers"] != [] and threshold > 0 and (get_in(record, ["counters", "integrations_conflict"]) || 0) >= threshold

    cond do
      failure -> failure_actions(record, failure, opts)
      trouble -> info_attention(record["ticket"], trouble)
      churn? -> info_attention(record["ticket"], {:trouble, hd(record["blockers"])["id"], :churn})
      Enum.all?(outcomes, &(&1 == :healthy)) -> [{:resolve, @cause, record["ticket"]}]
      true -> []
    end
  end

  defp failure_actions(record, {:failed, blocker, cause}, opts) do
    dep = record["ticket"]
    running = Keyword.get(opts, :running_dependents, MapSet.new([dep]))
    action = if MapSet.member?(running, dep), do: :paused_parked, else: :parked
    [{:park, dep, blocker, cause}, {:attention, @cause, dep, %{blocker: blocker, cause: cause, action: action, severity: "warning"}}]
  end

  defp info_attention(dep, {:trouble, blocker, cause}),
    do: [{:attention, @cause, dep, %{blocker: blocker, cause: cause, action: :none, severity: "info"}}]
end
