defmodule Aiur.Orchestrator.CommentWake.IdleRework do
  @moduledoc "Idle comment eligibility, refusals and rework outcomes."

  require Logger

  alias Aiur.Alerts
  alias Aiur.Issue
  alias Aiur.Orchestrator.CommentWake
  alias Aiur.Orchestrator.CommentWake.Dispatch
  alias Aiur.Orchestrator.CommentWake.ReworkRetries
  alias Aiur.Orchestrator.CommentWake.ReworkTransition
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.Tracker

  @doc false
  @spec maybe_transition_idle_issue_to_rework(
          State.t(),
          String.t() | integer(),
          String.t() | atom(),
          map(),
          pos_integer()
        ) :: State.t()
  def maybe_transition_idle_issue_to_rework(state, issue_number, source, event, attempt) do
    TrackerTasks.run(state, {:comment_idle, issue_number, source, make_ref()}, fn -> idle_rework_issue(state, issue_number, event) end, fn current, result ->
      if is_nil(State.find_running_by_identifier(current.running, issue_number)) do
        apply_idle_rework_decision(current, issue_number, source, event, attempt, idle_rework_decision_from_issue(result, event))
      else
        CommentWake.maybe_reactivate_on_comment(current, issue_number, source, event, attempt)
      end
    end)
  end

  defp apply_idle_rework_decision(state, issue_number, source, event, attempt, decision) do
    case decision do
      {:skip, reason} ->
        emit_idle_comment_refusal(issue_number, reason)

        Logger.info("#{source} ignored for idle issue: issue_identifier=#{issue_number} reason=#{inspect(reason)}")

        state = ReworkRetries.cancel_comment_rework_retry(state, issue_number, source)

        # `not_yet_attempted` is a skip of the *label transition* only, never of
        # the comment. The ticket is dispatchable and will be picked up, so the
        # comment has to survive into the digest the agent reads on its first
        # turn. Dropping it here would trade a wrong label for lost operator
        # input, which is the worse failure of the two.
        if reason == :not_yet_attempted,
          do: Dispatch.seed_idle_comment_wake_event(state, issue_number, event),
          else: state

      {:error, reason} ->
        emit_comment_rework_refusal(
          issue_number,
          "comment_wake_state_unresolved",
          "Comment on issue #{issue_number} could not be evaluated for rework",
          "Could not resolve the issue state (#{inspect(reason)}).",
          "check tracker access and retry the comment delivery"
        )

        Logger.warning(
          "#{source} rework gate skipped; issue state could not be resolved: " <>
            "issue_identifier=#{issue_number} reason=#{inspect(reason)}"
        )

        ReworkRetries.schedule_comment_rework_retry(state, issue_number, source, event, attempt, reason)

      :active ->
        ReworkTransition.with_comment_transition(state, issue_number, issue_number, source, event, nil, attempt, fn arg1 ->
          apply_idle_rework_outcome(
            arg1,
            {attempt, event, issue_number, source}
          )
        end)
    end
  end

  # A trusted comment on an IDLE issue is only rework feedback if the ticket is
  # actually a tracked, worked ticket — one carrying an `agent:*` state label.
  # A ticket with NO `agent:*` label is how an operator parks work ("decide
  # before this is built"): there is no prior implementation for "rework" to
  # mean anything about, and auto-flipping it to `agent:rework` silently
  # overrides that intent (#1971). The explicit `agent:parked` marker is the
  # positive form of the same hold and is refused the same way. The poll path
  # never dispatches such tickets, so this gate is what keeps the comment path
  # from being the invisible auto-writer that reaches them.
  defp idle_rework_decision_from_issue(result, event) do
    case result do
      {:ok, %Issue{} = issue} ->
        cond do
          Issue.held?(issue) ->
            {:skip, if(Issue.parked?(issue), do: :parked, else: :executor_owned)}

          DispatchPolicy.normalize_issue_state(issue.state) == "" ->
            {:skip, :unlabeled_issue}

          # Ordinary comments on a `todo` ticket remain briefing material:
          # there is no prior implementation to rework, and flipping the state
          # would discard operator triage. A formal live review is the narrow
          # exception because it proves an existing PR was rejected.
          #
          # Observed repeatedly: promoting a ticket to `agent:todo` and then
          # commenting to say why reliably un-promoted it on the next poll, so
          # promotion and commentary could not be done in the same breath.
          #
          # The skip seeds the event digest below so the dispatched agent gets
          # the operator's briefing on its first turn.
          not_yet_attempted?(issue, event) ->
            {:skip, :not_yet_attempted}

          true ->
            :active
        end

      # The tracker has no record to read the labels off — a non-GitHub backend
      # that does not index by id, or an issue this repo does not own. Absence of
      # a record is NOT evidence of a parked ticket, so the gate must fail open
      # and leave the pre-#1971 behaviour (attempt the transition, let the
      # tracker write decide) exactly as it was.
      {:ok, :unresolved} ->
        :active

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp not_yet_attempted?(%Issue{} = issue, event) do
    DispatchPolicy.normalize_issue_state(issue.state) == "todo" and
      not ReworkTransition.changes_requested_review?(event)
  end

  # Prefer the polled view already held in orchestrator state; fall back to an
  # authoritative tracker read (injectable via the event for tests) when this
  # issue was never polled — which is exactly the unlabelled/parked case.
  defp idle_rework_issue(%State{} = state, issue_number, event) do
    target = to_string(issue_number)

    case Enum.find(state.last_polled_issues, fn
           {_id, %Issue{id: id, identifier: identifier}} ->
             Issue.identifier_matches?(id, identifier, target)

           _ ->
             false
         end) do
      {_id, %Issue{} = issue} ->
        {:ok, issue}

      nil ->
        fetch_idle_rework_issue(issue_number, event)
    end
  end

  defp fetch_idle_rework_issue(issue_number, event) do
    fetcher =
      case Map.get(event, :issue_state_fetcher) do
        fun when is_function(fun, 1) -> fun
        _ -> &Tracker.fetch_issue_states_by_ids/1
      end

    case fetcher.([to_string(issue_number)]) do
      {:ok, [%Issue{} = issue | _]} -> {:ok, issue}
      {:ok, []} -> {:ok, :unresolved}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_idle_comment_refusal(issue_number, reason)
       when reason in [:parked, :unlabeled_issue, :no_open_pr, :rework_attempt_limit_reached] do
    remedy =
      case reason do
        :parked -> "resume the issue explicitly to clear the park marker"
        :unlabeled_issue -> "assign an agent state if this issue should be worked"
        :no_open_pr -> "open a pull request before requesting rework"
        :rework_attempt_limit_reached -> "move the ticket to rework or re-review it after addressing the gate condition"
      end

    Alerts.emit_custom(
      "ticket.#{issue_number}.agent.attention.comment_wake_idle_issue",
      "Comment on idle issue #{issue_number} was not acted on (#{inspect(reason)})",
      issue: to_string(issue_number),
      reason: "Idle issue rework gate refused the comment (#{inspect(reason)}). Remedy: #{remedy}.",
      needs_attention: false,
      severity: "info",
      event_source: :system
    )
  end

  defp emit_idle_comment_refusal(_issue_number, _reason), do: :ok

  defp emit_comment_rework_refusal(issue_number, suffix, message, reason, remedy) do
    Alerts.emit_custom(
      "ticket.#{issue_number}.agent.attention.#{suffix}",
      message,
      issue: to_string(issue_number),
      reason: "#{reason} Remedy: #{remedy}.",
      needs_attention: false,
      severity: "info",
      event_source: :system
    )
  end

  defp apply_idle_rework_outcome(
         outcome,
         {attempt, event, issue_number, source}
       ) do
    case outcome do
      {:ok, state} ->
        # The transition landed, so any retry still pending from an earlier
        # comment on this issue is now moot — cancel it rather than let it fire.
        state
        |> ReworkRetries.cancel_comment_rework_retry(issue_number, source)
        |> Dispatch.seed_idle_comment_wake_event(issue_number, event)

      {{:skip, reason}, state} ->
        emit_idle_comment_refusal(issue_number, reason)

        Logger.info("#{source} ignored for idle issue: issue_identifier=#{issue_number} reason=#{inspect(reason)}")
        # No seeding here, deliberately. An IDLE ticket in an active state
        # is still a dispatch candidate, so the poll loop picks it up and
        # the agent reads the comment from GitHub on its first turn. The
        # #2601 wake gap is the *running* half — a `:deactivated` entry
        # blocks re-dispatch (`DispatchPolicy`'s `:already_running`), so
        # nothing else brings that agent back. See
        # `Reactivation.transition_and_revalidate_comment_reactivation/5`.

        ReworkRetries.cancel_comment_rework_retry(state, issue_number, source)

      {{:error, reason}, state} ->
        emit_comment_rework_refusal(
          issue_number,
          "comment_wake_state_update_failed",
          "Comment on issue #{issue_number} could not update its rework state",
          "The rework state update failed (#{inspect(reason)}).",
          "check tracker permissions and retry the comment delivery"
        )

        Logger.warning("#{source} rework transition skipped; state update failed: issue_identifier=#{issue_number} reason=#{inspect(reason)}")

        ReworkRetries.schedule_comment_rework_retry(state, issue_number, source, event, attempt, reason)
    end
  end
end
