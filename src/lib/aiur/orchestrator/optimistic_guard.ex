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
    blockers = Enum.map(record["blockers"], &Map.put(&1, "conflicts_seen", conflict_reports(record, &1["id"])))
    results = Enum.map(blockers, &inspect_blocker(record["ticket"], &1, observations[&1["id"]], now, opts))
    updates = Enum.flat_map(results, &elem(&1, 0))
    outcomes = Enum.map(results, &elem(&1, 1))
    updates ++ record_actions(apply_updates(record, updates), outcomes, now, opts)
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

    recovered_blocker? = observation[:state_reason] in [:completed, "completed"] or observation[:pr_merged] == true or observation[:pr_state] in [:merged, "merged"]
    observation = Map.put(observation, :edge_present?, if(recovered_blocker?, do: true, else: edge_present))
    classification = classify(observation)
    observation_actions(dep, blocker, observation, classification, now, opts)
  end

  defp observation_actions(_dep, _blocker, _observation, :unknown, _now, _opts), do: {[], :unknown}

  defp observation_actions(dep, blocker, observation, classification, now, opts) do
    cause = suspect_cause(classification)
    since = suspect_since(blocker, observation, cause, now)
    facts = %{observed_at_ms: observation.observed_at_ms, suspect_since_ms: since, suspect_cause: cause}
    facts = Map.merge(facts, pr_facts(observation))
    facts = if observation[:pr_merged] == true or observation[:pr_state] in [:merged, "merged"], do: Map.put(facts, :merged_at_ms, observation[:pr_merged_at_ms] || now), else: facts
    facts = Map.merge(facts, approval_checkpoint(blocker, observation))
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

  defp pr_facts(observation) do
    facts = %{
      pr_number: observation[:pr_number],
      pr_state: observation[:pr_state] || if(observation[:any_open_pr?], do: "open", else: nil),
      last_head_sha: observation[:pr_head_sha],
      last_head_ref: observation[:pr_head_ref]
    }

    if is_integer(observation[:pr_approval_checked_conflicts]), do: Map.put(facts, :approval_checked_conflicts, observation[:pr_approval_checked_conflicts]), else: facts
  end

  defp outcome({:terminal, cause}, id, _since, _now, _opts), do: {:failed, id, cause}

  defp outcome({kind, cause}, id, since, now, opts) when kind in [:suspect, :trouble] do
    if now - since >= Keyword.get(opts, :grace_ms, 600_000) do
      if kind == :suspect, do: {:failed, id, cause}, else: {:trouble, id, cause}
    else
      :waiting
    end
  end

  defp outcome(classification, _id, _since, _now, _opts), do: classification

  defp record_actions(%{"status" => "parked"} = record, outcomes, now, _opts) do
    recovered = merged_blockers(record, now)
    recovered_ids = MapSet.new(recovered, & &1["id"])
    remaining = Enum.zip(record["blockers"], outcomes) |> Enum.reject(fn {blocker, _} -> MapSet.member?(recovered_ids, blocker["id"]) end)
    notices = Enum.map(recovered, &{:merged_notice, record["ticket"], &1["id"]})

    case first_failed(remaining) do
      {:failed, blocker, cause} ->
        notices ++ park_unfinished(record, blocker, cause)

      _ ->
        notices
    end
  end

  defp record_actions(record, outcomes, now, opts) do
    recovered = merged_blockers(record, now)
    recovered_ids = MapSet.new(recovered, & &1["id"])
    active = Enum.zip(record["blockers"], outcomes) |> Enum.reject(fn {blocker, _outcome} -> MapSet.member?(recovered_ids, blocker["id"]) end)
    failure = Enum.find_value(active, fn {_blocker, outcome} -> if match?({:failed, _, _}, outcome), do: outcome end)
    trouble = Enum.find_value(active, fn {_blocker, outcome} -> if match?({:trouble, _, _}, outcome), do: outcome end)
    notices = Enum.map(recovered, &{:merged_notice, record["ticket"], &1["id"]})

    notices ++ action_for(record, outcomes, active, recovered, failure, trouble, opts)
  end

  defp first_failed(blockers), do: Enum.find_value(blockers, fn {_blocker, outcome} -> if match?({:failed, _, _}, outcome), do: outcome end)

  defp park_unfinished(record, blocker, cause) do
    if Enum.any?(record["blockers"], &(&1["id"] == blocker and &1["park_complete"] == true)),
      do: [],
      else: [{:park, record["ticket"], blocker, cause}]
  end

  defp action_for(record, outcomes, active, recovered, failure, trouble, opts) do
    cond do
      failure -> failure_actions(record, failure, opts)
      trouble -> info_attention(record["ticket"], trouble)
      churn?(record, active, opts) -> churn_attention(record["ticket"], active)
      recovered == [] and Enum.all?(outcomes, &(&1 == :healthy)) -> [{:resolve, @cause, record["ticket"]}]
      true -> []
    end
  end

  defp churn_attention(ticket, active) do
    blocker = active |> hd() |> elem(0)
    info_attention(ticket, {:trouble, blocker["id"], :churn})
  end

  defp churn?(record, active, opts) do
    threshold = Keyword.get(opts, :churn_threshold, 3)
    active != [] and threshold > 0 and conflicts_since_approval(record, active) >= threshold
  end

  defp conflicts_since_approval(record, active) do
    Enum.reduce(active, 0, fn {blocker, _outcome}, total ->
      current = conflict_reports(record, blocker["id"])
      baseline = blocker["conflicts_at_approval"] || 0
      total + max(current - baseline, 0)
    end)
  end

  defp conflict_reports(record, blocker) do
    reports = Enum.filter(record["integration_reports"] || [], &(&1["blocker"] == blocker and &1["conflict"] == true))
    if reports == [] and length(record["blockers"]) == 1, do: get_in(record, ["counters", "integrations_conflict"]) || 0, else: length(reports)
  end

  defp approval_checkpoint(blocker, %{pr_approved?: true, pr_head_sha: head} = observation) when is_binary(head) do
    checked = observation[:pr_approval_checked_conflicts]

    if blocker["approval_head_sha"] == head and blocker["approval_active"] != false do
      if is_integer(checked), do: %{approval_checked_conflicts: checked}, else: %{}
    else
      %{approval_head_sha: head, approval_active: true, conflicts_at_approval: blocker["conflicts_seen"] || 0, approval_checked_conflicts: checked}
    end
  end

  defp approval_checkpoint(_blocker, %{pr_approved?: false, pr_approval_checked_conflicts: checked}) when is_integer(checked), do: %{approval_active: false, approval_checked_conflicts: checked}
  defp approval_checkpoint(_blocker, _observation), do: %{}

  defp apply_updates(record, updates) do
    Enum.reduce(updates, record, fn
      {:update_blocker, _dep, id, facts}, current ->
        facts = Map.new(facts, fn {key, value} -> {to_string(key), value} end)
        Map.update!(current, "blockers", &Enum.map(&1, fn blocker -> merge_blocker_facts(blocker, id, facts) end))

      _action, current ->
        current
    end)
  end

  defp merge_blocker_facts(%{"id" => id} = blocker, id, facts), do: Map.merge(blocker, facts)
  defp merge_blocker_facts(blocker, _id, _facts), do: blocker

  defp merged_blockers(record, now) do
    record["blockers"]
    |> Enum.filter(&(is_integer(&1["merged_at_ms"]) and &1["merged_at_ms"] <= now))
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
