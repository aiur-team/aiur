defmodule Aiur.Orchestrator.CiWaitDraftAlert do
  @moduledoc false

  alias Aiur.{AlertFeed, Alerts, Config, Issue}
  alias Aiur.Orchestrator.State

  @spec reconcile(State.t(), Issue.t(), map(), boolean(), keyword()) :: State.t()
  def reconcile(%State{} = state, %Issue{} = issue, result, in_ci_wait?, opts) do
    target = target(issue)

    if is_binary(target) do
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
    state = ensure_seeded(state, opts)
    tracked = Map.keys(since_map(state)) ++ MapSet.to_list(alerts(state))

    Enum.reduce(tracked -- targets, state, fn target, acc ->
      clear(acc, %Issue{id: target, identifier: target}, target, opts)
    end)
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

  defp ensure_seeded(%State{ci_lifecycle: %{ci_wait_draft_alerts: nil}} = state, opts) do
    alerts =
      case Keyword.fetch(opts, :ci_wait_draft_alert_loader) do
        {:ok, loader} -> loader.()
        :error -> [needs_attention: true] |> AlertFeed.list() |> Enum.reduce(MapSet.new(), &collect_target/2)
      end

    put_alerts(state, alerts)
  end

  defp ensure_seeded(state, _opts), do: state

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
  defp put_alerts(state, alerts), do: %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :ci_wait_draft_alerts, alerts)}
  defp alert_emitter(opts), do: Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

  defp log_failure(topic, reason, state) do
    require Logger
    Logger.warning("Draft CI-wait alert emission failed: topic=#{topic} reason=#{inspect(reason)}")
    state
  end
end
