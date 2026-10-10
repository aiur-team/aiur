defmodule Aiur.Orchestrator.CiLifecycle.DraftStallAlert do
  @moduledoc """
  Raises and resolves the alert for an approved, green pull request left as a draft.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.ParkedReadyAlert
  alias Aiur.Orchestrator.State
  require Logger

  @doc false
  @spec reconcile_draft_stall_alert(State.t(), Issue.t(), term(), term()) :: term()
  def reconcile_draft_stall_alert(%State{} = state, %Issue{} = issue, result, opts) do
    target = CiLifecycle.ci_target_for_issue(issue)

    if is_binary(target) do
      state
      |> ensure_draft_stall_alerts_seeded(opts)
      |> reconcile_draft_stall_alert_for_target(issue, result, target, opts)
    else
      state
    end
  end

  defp reconcile_draft_stall_alert_for_target(state, issue, result, target, opts) do
    active_alerts = Map.get(state.ci_lifecycle, :draft_stall_alerts, MapSet.new())

    case draft_stall_state(result) do
      :active ->
        emit_draft_stall_alert(state, issue, result, target, active_alerts, opts)

      status when status in [:clear, :pr_gone] ->
        resolve_draft_stall_alert(state, issue, result, target, active_alerts, opts)

      :unknown ->
        state
    end
  end

  defp draft_stall_state(result) do
    case pr_visibility_state(result) do
      :observable -> observed_draft_stall_state(result)
      visibility_state -> visibility_state
    end
  end

  # A PR the poll can no longer see is gone; one it cannot see yet is not an
  # observation at all, so neither can decide a stall.
  defp pr_visibility_state(result) do
    case Map.get(result, :pending_reason) do
      :open_pr_no_longer_visible -> :pr_gone
      :open_pr_not_yet_visible -> :unknown
      _other -> :observable
    end
  end

  defp observed_draft_stall_state(result) do
    cond do
      not complete_draft_observation?(result) -> :unknown
      stall_ruled_out?(result) -> :clear
      true -> draft_review_state(result)
    end
  end

  defp complete_draft_observation?(result) do
    Map.has_key?(result, :decision) and Map.has_key?(result, :draft?)
  end

  # CI that is not green, or a PR that is no longer a draft, cannot be stalled
  # by the draft gate.
  defp stall_ruled_out?(result) do
    Map.get(result, :decision) != :passed or Map.get(result, :draft?) == false
  end

  defp draft_review_state(result) do
    if Map.get(result, :draft?) == true do
      review_decision_state(Map.get(result, :review_decision))
    else
      :unknown
    end
  end

  defp review_decision_state("APPROVED"), do: :active
  defp review_decision_state(review_decision) when is_binary(review_decision), do: :clear
  defp review_decision_state(_review_decision), do: :unknown

  defp emit_draft_stall_alert(state, issue, result, target, active_alerts, opts) do
    if MapSet.member?(active_alerts, target) do
      state
    else
      topic = draft_stall_alert_topic(target)
      pr_number = Map.get(result, :pr_number)
      message = "Approved and CI-green PR ##{pr_number} is still a draft and cannot auto-merge"

      case ParkedReadyAlert.alert_emitter(opts).(topic,
             issue: issue,
             central: true,
             message: message,
             reason:
               "A draft blocks the merge queue: the PR is approved, CI is green, and it is still " <>
                 "a draft (#1974). Mark the PR ready to resume auto-merge; until then finished work sits.",
             needs_attention: true
           ) do
        :ok -> put_draft_stall_alerts(state, MapSet.put(active_alerts, target))
        {:error, reason} -> log_draft_stall_alert_error(state, topic, reason)
      end
    end
  end

  defp resolve_draft_stall_alert(state, issue, result, target, active_alerts, opts) do
    if MapSet.member?(active_alerts, target) do
      topic = draft_stall_alert_topic(target) <> ".resolved"

      message =
        case Map.get(result, :pr_number) do
          pr_number when is_integer(pr_number) ->
            "Pull request ##{pr_number} is no longer approved, CI-green, and draft."

          _ ->
            "Ticket #{target} is no longer stalled by an approved, CI-green draft pull request."
        end

      case ParkedReadyAlert.alert_emitter(opts).(topic,
             issue: issue,
             central: true,
             message: message,
             reason: message,
             needs_attention: false
           ) do
        :ok -> put_draft_stall_alerts(state, MapSet.delete(active_alerts, target))
        {:error, reason} -> log_draft_stall_alert_error(state, topic, reason)
      end
    else
      state
    end
  end

  defp draft_stall_alert_topic(target), do: "ticket.#{target}.pr.draft_approved_green"

  defp put_draft_stall_alerts(%State{} = state, alerts) do
    %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :draft_stall_alerts, alerts)}
  end

  defp log_draft_stall_alert_error(state, topic, reason) do
    Logger.warning("Draft-stall alert emission failed: topic=#{topic} reason=#{inspect(reason)}")
    state
  end

  @doc false
  @spec ensure_draft_stall_alerts_seeded(State.t(), term()) :: term()
  def ensure_draft_stall_alerts_seeded(%State{} = state, opts) do
    case Map.get(state.ci_lifecycle, :draft_stall_alerts) do
      nil ->
        alerts = ParkedReadyAlert.seed_active_alerts(opts, :draft_stall_alert_loader, "draft_approved_green")
        %{state | ci_lifecycle: Map.put(state.ci_lifecycle, :draft_stall_alerts, alerts)}

      _alerts ->
        state
    end
  end

  # ---- Parked-ready recovery alert ------------------------------------------
  #
  # A readied pull request that is approved, conflict-free, and still unarmed
  # will not re-enter the merge queue on its own (the recovery gap in #1737).
  # `mergeStateStatus: BLOCKED` on a freshly readied PR is not a merge conflict,
  # so the classifier keys eligibility on `mergeable` and deliberately ignores
  # the queue-status field. The daemon never arms auto-merge (the human-only
  # merge gate in #1841): it surfaces the parked state so the Executor can take
  # the documented explicit action (`gh pr merge <n> --squash --delete-branch
  # --auto`, per #1854).
end
