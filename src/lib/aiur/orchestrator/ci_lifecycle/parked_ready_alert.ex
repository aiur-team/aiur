defmodule Aiur.Orchestrator.CiLifecycle.ParkedReadyAlert do
  @moduledoc """
  Raises and resolves the alert for a ready pull request parked outside review.
  """

  alias Aiur.AlertFeed
  alias Aiur.Alerts
  alias Aiur.GitHub.MergeQueue
  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.Transition
  alias Aiur.Orchestrator.HumanReview
  alias Aiur.Orchestrator.State
  require Logger

  @doc false
  @spec reconcile_parked_ready_alert(State.t(), Issue.t(), term(), term()) :: term()
  def reconcile_parked_ready_alert(%State{} = state, %Issue{} = issue, result, opts) do
    target = CiLifecycle.ci_target_for_issue(issue)

    if is_binary(target) do
      state
      |> ensure_parked_ready_alerts_seeded(opts)
      |> reconcile_parked_ready_alert_for_target(issue, result, target, opts)
    else
      state
    end
  end

  defp reconcile_parked_ready_alert_for_target(state, issue, result, target, opts) do
    active_alerts = Map.get(state.ci_lifecycle, :parked_ready_alerts, MapSet.new())
    recovery = parked_ready_recovery(result)
    in_human_review = HumanReview.human_review_state?(Transition.effective_ci_state(issue))

    cond do
      in_human_review and recovery == :active ->
        emit_parked_ready_alert(state, issue, result, target, active_alerts, opts)

      in_human_review and recovery in [:clear, :pr_gone] ->
        resolve_parked_ready_alert(state, issue, result, target, active_alerts, opts)

      in_human_review ->
        state

      MapSet.member?(active_alerts, target) ->
        # The issue left human-review (e.g. returned to ci-wait for a fresh
        # head or passed CI back to the agent); the parked condition no longer
        # holds, so clear the alert.
        resolve_parked_ready_alert(state, issue, result, target, active_alerts, opts)

      true ->
        state
    end
  end

  # :active => approved + ready + mergeable + unarmed; :clear => armed, queued,
  # or ineligible; :pr_gone => the open PR is no longer visible (merged or
  # closed) while the poll still targets the issue; :unknown => transient poll
  # failure or an incomplete observation, left untouched so a spurious error
  # never resolves and then re-fires a parked alert on the next tick.
  defp parked_ready_recovery(result) do
    case merge_queue_observation(result) do
      {:ok, observation} ->
        case MergeQueue.recovery_state(observation) do
          :unarmed -> :active
          :armed -> :clear
          :queued -> :clear
          :ineligible -> :clear
          :unknown -> :unknown
        end

      :error ->
        if Map.get(result, :pending_reason) in [:open_pr_not_yet_visible, :open_pr_no_longer_visible],
          do: :pr_gone,
          else: :unknown
    end
  end

  defp merge_queue_observation(result) do
    keys = [:draft?, :review_decision, :mergeable, :auto_merge_request, :merge_queue_entry]

    if Enum.all?(keys, &Map.has_key?(result, &1)) do
      {:ok, Map.take(result, keys)}
    else
      :error
    end
  end

  defp emit_parked_ready_alert(state, issue, result, target, active_alerts, opts) do
    if MapSet.member?(active_alerts, target) do
      state
    else
      topic = parked_ready_alert_topic(target)
      pr_number = Map.get(result, :pr_number)

      message =
        "Pull request ##{pr_number} is approved, ready, and mergeable but has no auto-merge request, " <>
          "so it will not re-enter the merge queue on its own. Re-arm it with " <>
          "`aiur pr merge #{pr_number} --reviewed-sha #{Map.get(result, :head_sha)}`."

      case alert_emitter(opts).(topic,
             issue: issue,
             central: true,
             message: message,
             reason: message,
             needs_attention: true
           ) do
        :ok -> put_parked_ready_alerts(state, MapSet.put(active_alerts, target))
        {:error, reason} -> log_parked_ready_alert_error(state, topic, reason)
      end
    end
  end

  defp resolve_parked_ready_alert(state, issue, result, target, active_alerts, opts) do
    if MapSet.member?(active_alerts, target) do
      topic = parked_ready_alert_topic(target) <> ".resolved"

      message =
        case Map.get(result, :pr_number) do
          pr_number when is_integer(pr_number) ->
            "Pull request ##{pr_number} is no longer approved, ready, and mergeable but unarmed."

          _ ->
            "Ticket #{target} is no longer in the parked-ready state."
        end

      case alert_emitter(opts).(topic,
             issue: issue,
             central: true,
             message: message,
             reason: message,
             needs_attention: false
           ) do
        :ok -> put_parked_ready_alerts(state, MapSet.delete(active_alerts, target))
        {:error, reason} -> log_parked_ready_alert_error(state, topic, reason)
      end
    else
      state
    end
  end

  # A target that left the CI poll set (issue reworked, PR merged/closed) is no
  # longer observed by the reconcile path; emit the resolution here so the
  # durable ledger clears and a later restart does not re-seed a stale alert.
  @doc false
  @spec resolve_departed_parked_ready_alerts(State.t(), term(), term()) :: term()
  def resolve_departed_parked_ready_alerts(%State{} = state, targets, opts) do
    active_alerts = Map.get(state.ci_lifecycle, :parked_ready_alerts, MapSet.new())
    departed = MapSet.difference(active_alerts, MapSet.new(targets))

    Enum.reduce(departed, state, fn target, state_acc ->
      resolve_parked_ready_alert(
        state_acc,
        target,
        %{pr_number: nil},
        target,
        Map.get(state_acc.ci_lifecycle, :parked_ready_alerts, MapSet.new()),
        opts
      )
    end)
  end

  defp parked_ready_alert_topic(target), do: "ticket.#{target}.pr.parked_ready"

  defp alert_emitter(opts), do: Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

  defp put_parked_ready_alerts(%State{} = state, alerts) do
    %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :parked_ready_alerts, alerts)}
  end

  defp log_parked_ready_alert_error(state, topic, reason) do
    Logger.warning("Parked-ready alert emission failed: topic=#{topic} reason=#{inspect(reason)}")
    state
  end

  @doc false
  @spec ensure_parked_ready_alerts_seeded(State.t(), term()) :: term()
  def ensure_parked_ready_alerts_seeded(%State{} = state, opts) do
    case Map.get(state.ci_lifecycle, :parked_ready_alerts) do
      nil ->
        %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :parked_ready_alerts, seed_parked_ready_alerts(opts))}

      _alerts ->
        state
    end
  end

  # Reload active alerts from the durable ledger so the first boot poll does not
  # re-fire it for a still-parked PR. Targets that left the poll set entirely
  # are resolved by `resolve_departed_parked_ready_alerts/3` instead.
  defp seed_parked_ready_alerts(opts) do
    seed_active_alerts(opts, :parked_ready_alert_loader, "parked_ready")
  end

  defp seed_active_alerts(opts, loader_key, alert_name) do
    case Keyword.fetch(opts, loader_key) do
      {:ok, loader} ->
        loader.()

      :error ->
        [needs_attention: true]
        |> AlertFeed.list()
        |> Enum.reduce(MapSet.new(), &collect_active_alert_target(&1, &2, alert_name))
    end
  end

  defp collect_active_alert_target(alert, acc, alert_name) do
    case active_pr_alert_target(alert, alert_name) do
      nil -> acc
      target -> MapSet.put(acc, target)
    end
  end

  defp active_pr_alert_target(%{"topic" => "ticket." <> rest}, alert_name) do
    case String.split(rest, ".", parts: 3) do
      [target, "pr", ^alert_name] -> target
      _ -> nil
    end
  end

  defp active_pr_alert_target(_alert, _alert_name), do: nil
end
