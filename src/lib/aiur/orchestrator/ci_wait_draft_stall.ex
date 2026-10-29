defmodule Aiur.Orchestrator.CiWaitDraftStall do
  @moduledoc false

  alias Aiur.{AlertFeed, Config, Issue, Signal}
  alias Aiur.Orchestrator.{LifecycleFence, State, TicketTransition}
  require Logger

  @spec reconcile(State.t(), Issue.t(), map(), boolean(), keyword()) :: State.t()
  def reconcile(state, issue, result, in_ci_wait?, opts) do
    target = target(issue)

    if is_binary(target) do
      state = ensure_seeded(state, opts)

      if Map.get(result, :pending_reason) == :draft_pull_request and in_ci_wait? do
        observe(state, issue, result, target, opts)
      else
        clear(state, target, opts)
      end
    else
      state
    end
  end

  @spec resolve_departed(State.t(), [String.t()], keyword()) :: State.t()
  def resolve_departed(state, targets, opts) do
    state = ensure_seeded(state, opts)
    tracked = Map.keys(since_map(state)) ++ MapSet.to_list(alerts(state)) ++ MapSet.to_list(recovered(state))

    Enum.reduce(tracked -- targets, state, fn target, acc -> clear(acc, target, opts) end)
  end

  defp observe(state, issue, result, target, opts) do
    now_ms = Keyword.get(opts, :ci_wait_draft_now_ms, System.monotonic_time(:millisecond))
    since = Map.get(since_map(state), target, now_ms)
    state = put_since(state, Map.put_new(since_map(state), target, now_ms))
    timeout_ms = Keyword.get(opts, :ci_wait_draft_timeout_minutes, 60) * 60_000
    recovery_alerted? = MapSet.member?(alerts(state), target)

    cond do
      live_worker?(state, issue) -> state
      now_ms - since >= timeout_ms and not MapSet.member?(recovered(state), target) -> recover(state, issue, result, target, opts)
      now_ms - since >= Keyword.get(opts, :ci_wait_rewake_minutes, Config.ci_wait_rewake_minutes()) * 60_000 and not recovery_alerted? -> emit(state, issue, result, target, opts)
      true -> state
    end
  end

  defp live_worker?(state, issue) do
    case Map.get(state.running, issue.id) do
      %{pid: pid, control: %{status: status}} when is_pid(pid) and status in [:working, :starting, :resuming] -> Process.alive?(pid)
      _ -> false
    end
  end

  defp recover(state, issue, result, target, opts) do
    message = "PR is still a draft; finish and mark ready"
    issue_id = issue.id || issue.identifier
    comment = Keyword.get(opts, :draft_stall_comment, fn id, body -> TicketTransition.write_comment(id, body, writer: :ci_lifecycle, tracker: Keyword.get(opts, :tracker, Aiur.Tracker)) end)
    transition = Keyword.get(opts, :draft_stall_transition, fn current, ticket -> transition_to_rework(current, ticket, opts) end)

    case comment.(issue_id, message) do
      :ok ->
        continue_recovery(state, issue, result, target, opts, transition)

      {:error, reason} ->
        Logger.warning("Draft CI-wait recovery comment failed: ticket=#{target} reason=#{inspect(reason)}")
        state

      other ->
        Logger.warning("Draft CI-wait recovery comment returned unexpected result: ticket=#{target} result=#{inspect(other)}")
        state
    end
  end

  defp continue_recovery(state, issue, result, target, opts, transition) do
    state = if MapSet.member?(alerts(state), target), do: state, else: emit(state, issue, result, target, opts)

    if MapSet.member?(alerts(state), target) do
      finish_recovery(transition.(state, issue), state, issue, result, target, opts)
    else
      state
    end
  end

  defp finish_recovery({:ok, state}, _previous_state, issue, result, target, opts) do
    state = put_recovered(state, MapSet.put(recovered(state), target))
    if MapSet.member?(alerts(state), target), do: state, else: emit(state, issue, result, target, opts)
  end

  defp finish_recovery({:error, reason, state}, _previous_state, _issue, _result, target, _opts) do
    Logger.warning("Draft CI-wait recovery transition failed: ticket=#{target} reason=#{inspect(reason)}")
    state
  end

  defp finish_recovery(other, previous_state, _issue, _result, target, _opts) do
    Logger.warning("Draft CI-wait recovery transition returned unexpected result: ticket=#{target} result=#{inspect(other)}")
    previous_state
  end

  defp transition_to_rework(state, issue, opts) do
    if LifecycleFence.handoff_blocked?(state, issue) do
      {:error, :lifecycle_fence, state}
    else
      opts =
        Keyword.merge(expected_state_opts(issue),
          writer: :ci_lifecycle,
          current_labels: List.wrap(issue.labels),
          tracker: Keyword.get(opts, :tracker, Aiur.Tracker)
        )

      case TicketTransition.write_state(to_string(issue.id || issue.identifier), "rework", opts) do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp expected_state_opts(%Issue{state: state}) when is_binary(state), do: [expected_state: state]
  defp expected_state_opts(_issue), do: []

  defp emit(state, issue, result, target, opts) do
    topic = "ticket.#{target}.pr.draft_ci_wait"
    message = "Ticket #{target} PR ##{Map.get(result, :pr_number) || "unknown"} is still a draft; finish and mark ready"

    case alert_emitter(opts).(topic, issue: issue, central: true, message: message, reason: message, needs_attention: true) do
      :ok -> put_alerts(state, MapSet.put(alerts(state), target))
      {:error, reason} -> log_failure(topic, reason, state)
    end
  end

  defp clear(state, target, opts) do
    state = put_since(state, Map.delete(since_map(state), target))
    state = put_recovered(state, MapSet.delete(recovered(state), target))

    if MapSet.member?(alerts(state), target) do
      topic = "ticket.#{target}.pr.draft_ci_wait.resolved"

      case alert_emitter(opts).(topic,
             issue: %Issue{id: target, identifier: target},
             central: true,
             message: "Ticket #{target} is no longer waiting on draft PR checks",
             reason: "The PR is ready or no longer visible.",
             needs_attention: false
           ) do
        :ok -> put_alerts(state, MapSet.delete(alerts(state), target))
        {:error, reason} -> log_failure(topic, reason, state)
      end
    else
      state
    end
  end

  defp ensure_seeded(state, opts) do
    if is_nil(Map.get(state.ci_lifecycle, :ci_wait_draft_alerts)) do
      state |> put_alerts(load_alerts(opts))
    else
      state
    end
  end

  defp load_alerts(opts) do
    case Keyword.fetch(opts, :ci_wait_draft_alert_loader) do
      {:ok, loader} -> loader.()
      :error -> [needs_attention: true] |> AlertFeed.list() |> Enum.reduce(MapSet.new(), &collect_target/2)
    end
  end

  defp collect_target(%{"topic" => "ticket." <> rest}, acc) do
    case String.split(rest, ".", parts: 3) do
      [target, "pr", "draft_ci_wait"] -> MapSet.put(acc, target)
      _ -> acc
    end
  end

  defp collect_target(_alert, acc), do: acc
  defp target(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier
  defp target(%Issue{id: id}) when is_binary(id) and id != "", do: id
  defp target(_issue), do: nil
  defp since_map(state), do: Map.get(state.ci_lifecycle, :ci_wait_draft_since, %{})
  defp alerts(state), do: Map.get(state.ci_lifecycle, :ci_wait_draft_alerts) || MapSet.new()
  defp put_since(state, since), do: %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :ci_wait_draft_since, since)}
  defp put_alerts(state, items), do: %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :ci_wait_draft_alerts, items)}
  defp recovered(state), do: Map.get(state.ci_lifecycle, :ci_wait_draft_recovered, MapSet.new())
  defp put_recovered(state, targets), do: %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :ci_wait_draft_recovered, targets)}
  defp alert_emitter(opts), do: Keyword.get(opts, :alert_emitter, &Signal.alert/2)

  defp log_failure(topic, reason, state) do
    Logger.warning("Draft CI-wait alert emission failed: topic=#{topic} reason=#{inspect(reason)}")
    state
  end
end
