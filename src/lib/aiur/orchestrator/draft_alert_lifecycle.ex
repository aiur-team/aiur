defmodule Aiur.Orchestrator.DraftAlertLifecycle do
  @moduledoc false

  alias Aiur.{AlertFeed, Alerts, Config, Issue}
  alias Aiur.Orchestrator.State
  require Logger

  @spec reconcile(State.t(), Issue.t(), map(), boolean(), keyword()) :: State.t()
  def reconcile(%State{} = state, %Issue{} = issue, result, in_ci_wait?, opts) do
    target = target(issue)

    if is_binary(target) do
      state = reconcile_draft_stall(state, issue, result, target, opts)
      state = ensure_seeded(state, opts)

      if Map.get(result, :pending_reason) == :draft_pull_request and in_ci_wait? do
        observe(state, issue, result, target, opts)
      else
        clear(state, issue, target, opts)
      end
    else
      state
    end
  end

  @spec resolve_departed(State.t(), [String.t()], keyword()) :: State.t()
  def resolve_departed(%State{} = state, targets, opts) do
    state = state |> ensure_draft_stall_seeded(opts) |> ensure_seeded(opts)
    tracked = Map.keys(since_map(state)) ++ MapSet.to_list(alerts(state))

    Enum.reduce(tracked -- targets, state, fn target, acc ->
      clear(acc, %Issue{id: target, identifier: target}, target, opts)
    end)
  end

  @spec keep_pending_reason(map(), map()) :: map()
  def keep_pending_reason(projection, result) do
    case Map.get(result, :pending_reason) do
      nil -> projection
      reason -> Map.put(projection, :pending_reason, reason)
    end
  end

  defp reconcile_draft_stall(state, issue, result, target, opts) do
    state = ensure_draft_stall_seeded(state, opts)
    active_alerts = Map.get(state.ci_lifecycle, :draft_stall_alerts, MapSet.new())

    case draft_stall_state(result) do
      :active -> emit_draft_stall_alert(state, issue, result, target, active_alerts, opts)
      status when status in [:clear, :pr_gone] -> resolve_draft_stall_alert(state, issue, result, target, active_alerts, opts)
      :unknown -> state
    end
  end

  defp draft_stall_state(result) do
    case Map.get(result, :pending_reason) do
      :open_pr_no_longer_visible -> :pr_gone
      :open_pr_not_yet_visible -> :unknown
      _ -> observed_draft_stall_state(result)
    end
  end

  defp observed_draft_stall_state(result) do
    cond do
      not (Map.has_key?(result, :decision) and Map.has_key?(result, :draft?)) -> :unknown
      Map.get(result, :decision) != :passed or Map.get(result, :draft?) == false -> :clear
      Map.get(result, :draft?) == true -> review_decision_state(Map.get(result, :review_decision))
      true -> :unknown
    end
  end

  defp review_decision_state("APPROVED"), do: :active
  defp review_decision_state(review_decision) when is_binary(review_decision), do: :clear
  defp review_decision_state(_review_decision), do: :unknown

  defp emit_draft_stall_alert(state, issue, result, target, active_alerts, opts) do
    if MapSet.member?(active_alerts, target) do
      state
    else
      topic = "ticket.#{target}.pr.draft_approved_green"
      pr_number = Map.get(result, :pr_number)
      message = "Approved and CI-green PR ##{pr_number} is still a draft and cannot auto-merge"

      case alert_emitter(opts).(topic,
             issue: issue,
             central: true,
             message: message,
             reason: "A draft blocks the merge queue: the PR is approved, CI is green, and it is still a draft (#1974). Mark the PR ready to resume auto-merge; until then finished work sits.",
             needs_attention: true
           ) do
        :ok -> put_draft_stall_alerts(state, MapSet.put(active_alerts, target))
        {:error, reason} -> log_draft_stall_alert_error(topic, reason, state)
      end
    end
  end

  defp resolve_draft_stall_alert(state, issue, result, target, active_alerts, opts) do
    if MapSet.member?(active_alerts, target) do
      topic = "ticket.#{target}.pr.draft_approved_green.resolved"

      message =
        if is_integer(result[:pr_number]),
          do: "Pull request ##{result.pr_number} is no longer approved, CI-green, and draft.",
          else: "Ticket #{target} is no longer stalled by an approved, CI-green draft pull request."

      case alert_emitter(opts).(topic, issue: issue, central: true, message: message, reason: message, needs_attention: false) do
        :ok -> put_draft_stall_alerts(state, MapSet.delete(active_alerts, target))
        {:error, reason} -> log_draft_stall_alert_error(topic, reason, state)
      end
    else
      state
    end
  end

  defp ensure_draft_stall_seeded(state, opts) do
    if is_nil(Map.get(state.ci_lifecycle, :draft_stall_alerts)) do
      put_draft_stall_alerts(state, load_alerts(opts, :draft_stall_alert_loader, "draft_approved_green"))
    else
      state
    end
  end

  defp put_draft_stall_alerts(state, alerts), do: %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :draft_stall_alerts, alerts)}

  defp log_draft_stall_alert_error(topic, reason, state) do
    Logger.warning("Draft-stall alert emission failed: topic=#{topic} reason=#{inspect(reason)}")
    state
  end

  defp observe(state, issue, result, target, opts) do
    now_ms = Keyword.get(opts, :ci_wait_draft_now_ms, System.monotonic_time(:millisecond))
    since_map = since_map(state)
    since = Map.get(since_map, target, now_ms)
    state = put_since(state, Map.put_new(since_map, target, now_ms))

    if now_ms - since >= Config.ci_wait_rewake_minutes() * 60_000 and not MapSet.member?(alerts(state), target) do
      emit(state, issue, result, target, opts)
    else
      state
    end
  end

  defp emit(state, issue, result, target, opts) do
    topic = "ticket.#{target}.pr.draft_ci_wait"
    message = "PR ##{Map.get(result, :pr_number) || "unknown"} is still a draft; mark it ready for CI wait to finish"

    case alert_emitter(opts).(topic, issue: issue, central: true, message: message, reason: message, needs_attention: true) do
      :ok -> put_alerts(state, MapSet.put(alerts(state), target))
      {:error, reason} -> log_failure(topic, reason, state)
    end
  end

  defp clear(state, issue, target, opts) do
    state = put_since(state, Map.delete(since_map(state), target))

    if MapSet.member?(alerts(state), target) do
      resolve(state, issue, target, opts)
    else
      state
    end
  end

  defp resolve(state, issue, target, opts) do
    topic = "ticket.#{target}.pr.draft_ci_wait.resolved"

    case alert_emitter(opts).(topic,
           issue: issue,
           central: true,
           message: "Ticket #{target} is no longer waiting on draft PR checks",
           reason: "The PR is ready or no longer visible.",
           needs_attention: false
         ) do
      :ok -> put_alerts(state, MapSet.delete(alerts(state), target))
      {:error, reason} -> log_failure(topic, reason, state)
    end
  end

  defp ensure_seeded(state, opts) do
    if is_nil(Map.get(state.ci_lifecycle, :ci_wait_draft_alerts)) do
      alerts =
        load_alerts(opts, :ci_wait_draft_alert_loader, "draft_ci_wait")

      put_alerts(state, alerts)
    else
      state
    end
  end

  defp load_alerts(opts, loader_key, alert_name) do
    case Keyword.fetch(opts, loader_key) do
      {:ok, loader} -> loader.()
      :error -> [needs_attention: true] |> AlertFeed.list() |> Enum.reduce(MapSet.new(), &collect_target(&1, &2, alert_name))
    end
  end

  defp collect_target(%{"topic" => "ticket." <> rest}, acc, alert_name) do
    case String.split(rest, ".", parts: 3) do
      [target, "pr", ^alert_name] -> MapSet.put(acc, target)
      _ -> acc
    end
  end

  defp collect_target(_alert, acc, _alert_name), do: acc
  defp target(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier
  defp target(%Issue{id: id}) when is_binary(id) and id != "", do: id
  defp target(_issue), do: nil
  defp since_map(state), do: Map.get(state.ci_lifecycle, :ci_wait_draft_since, %{})
  defp alerts(state), do: Map.get(state.ci_lifecycle, :ci_wait_draft_alerts) || MapSet.new()
  defp put_since(state, since), do: %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :ci_wait_draft_since, since)}
  defp put_alerts(state, alerts), do: %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :ci_wait_draft_alerts, alerts)}
  defp alert_emitter(opts), do: Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

  defp log_failure(topic, reason, state) do
    Logger.warning("Draft CI-wait alert emission failed: topic=#{topic} reason=#{inspect(reason)}")
    state
  end
end
