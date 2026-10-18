defmodule Aiur.Orchestrator.EventTopics do
  @moduledoc """
  Parses and classifies orchestrator event bus topics.
  """

  alias Aiur.Orchestrator.{
    BlockerPropagation,
    CiLifecycle,
    CommentWake,
    Dispatcher,
    Lifecycle,
    MergedTicketReconciler.StrandedWork,
    MergeOrderAudit,
    OptimisticEvents,
    OptimisticGuardEffects,
    PushRouting,
    RestackScheduler,
    ReviewLandingWithdrawal,
    State
  }

  alias Aiur.Commands

  @spec route(State.t(), map(), keyword()) :: State.t()
  def route(state, event, opts \\ [])

  def route(%State{} = state, %{topic: topic} = event, opts) when is_binary(topic),
    do: route_classified(state, classify_event_topic(topic), event, opts)

  defp route_classified(state, :nomatch, _event, _opts), do: state

  defp route_classified(state, {:pr_review_comment, identifier}, event, _opts),
    do:
      state
      |> ReviewLandingWithdrawal.changes_requested(identifier, event)
      |> CommentWake.maybe_reactivate_on_comment(identifier, "PR review comment", event)

  defp route_classified(state, {:issue_commented, identifier}, event, _opts),
    do: CommentWake.maybe_reactivate_on_comment(state, identifier, "issue comment", event)

  defp route_classified(state, {:pr_merged, identifier}, event, _opts),
    do:
      state
      |> OptimisticEvents.merged(identifier, event)
      |> StrandedWork.mark_merged(identifier, pr_merged_opts(event))
      |> RestackScheduler.merged(identifier, event)
      |> MergeOrderAudit.merged(identifier, event)

  defp route_classified(state, {:optimistic_blocker_changed, identifier}, _event, _opts),
    do: OptimisticGuardEffects.reconcile(state, force_blocker: identifier)

  defp route_classified(state, {:ci_failed, identifier}, _event, _opts),
    do: CiLifecycle.maybe_resume_for_ci_terminal(state, identifier, :failed)

  defp route_classified(state, {:ci_passed, identifier}, _event, _opts),
    do: CiLifecycle.maybe_resume_for_ci_terminal(state, identifier, :passed)

  defp route_classified(state, {:pause_request, identifier}, event, _opts),
    do: PushRouting.maybe_pause_on_request(state, identifier, event)

  # Answering a blocking Command releases the dispatch gate in DecisionStore.
  # Refresh the local gate for control calls, then wake the poll to reclaim a worker that
  # reconciliation stopped while the Command was open. The dispatch poll still
  # applies tracker, capacity, and other open-Command guards.
  defp route_classified(state, {:decision_answered, _identifier}, _event, opts) do
    decision_store = Keyword.get(opts, :decision_store, Commands.default_store())

    state
    |> Dispatcher.refresh_blocked_ticket_ids(decision_store)
    |> Lifecycle.wake_tick()
  end

  defp route_classified(
         state,
         {:agent_unblocked, blocker_identifier},
         %{topic: topic} = event,
         _opts
       ) do
    cond do
      provisional_unblock?(event) ->
        state

      metadata = PushRouting.validated_unblock_metadata(blocker_identifier, event) ->
        PushRouting.maybe_resume_blockees_on_unblocked(state, blocker_identifier, topic, metadata)

      true ->
        state
    end
  end

  defp route_classified(state, {:optimistic_integrated, identifier}, event, _opts),
    do: OptimisticEvents.integrated(state, identifier, event)

  defp route_classified(state, {:branch_push, blocker_identifier}, event, opts) do
    payload = Map.get(event, :payload) || Map.get(event, "payload") || event

    if Map.get(payload, :superseded, Map.get(payload, "superseded", false)) do
      state
    else
      state = PushRouting.check_pr_body_head(state, blocker_identifier, event, opts)

      if PushRouting.validated_unblock_metadata(blocker_identifier, event) do
        state
        |> PushRouting.record_blocker_branch_push(blocker_identifier, event)
        |> OptimisticEvents.pushed(blocker_identifier, event)
        |> BlockerPropagation.pushed(blocker_identifier, event)
      else
        state
      end
    end
  end

  defp route_classified(state, {:system_branch_push, branch}, event, _opts),
    do: PushRouting.maybe_notify_agents_on_default_branch_push(state, branch, event)

  @doc """
  What the merged-PR route reads off a `ticket.<id>.pr.merged` event.

  The topic's identifier comes from the `aiur/<id>-<slug>` head branch, which
  says the PR belongs to the ticket but not that it completes it — so the PR
  body travels with it. Only the body can distinguish `Closes #N` from `Refs
  #N`, and closing a ticket the PR never claimed to close retires an operator's
  open acceptance checklist (#2609).
  """
  @spec pr_merged_opts(map()) :: keyword()
  def pr_merged_opts(event) when is_map(event) do
    pr = if is_map(Map.get(event, :pr)), do: Map.get(event, :pr), else: %{}

    opts = [
      merged_by_login: get_in(pr, ["merged_by", "login"]),
      pr_body: Map.get(pr, "body"),
      head_sha: get_in(pr, ["head", "sha"])
    ]

    if Map.has_key?(pr, "number"), do: Keyword.put(opts, :pr_number, pr["number"]), else: opts
  end

  defp provisional_unblock?(event) do
    Enum.any?(
      [event, Map.get(event, :payload), Map.get(event, "payload")],
      &temporary_stub?/1
    )
  end

  defp temporary_stub?(value) when is_map(value),
    do: Map.get(value, :temporary_stub) == true or Map.get(value, "temporary_stub") == true

  defp temporary_stub?(_value), do: false

  @spec parse_pr_review_comment_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_pr_review_comment_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.pr\.review_comment\z}, topic) do
      [_, number] -> {:ok, number}
      _ -> :nomatch
    end
  end

  @spec parse_issue_commented_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_issue_commented_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.issue\.commented\z}, topic) do
      [_, number] -> {:ok, number}
      _ -> :nomatch
    end
  end

  @spec parse_pr_merged_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_pr_merged_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.pr\.merged\z}, topic) do
      [_, number] -> {:ok, number}
      _ -> :nomatch
    end
  end

  @spec parse_ci_failed_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_ci_failed_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.ci\.failed\z}, topic) do
      [_, number] -> {:ok, number}
      _ -> :nomatch
    end
  end

  @spec parse_ci_passed_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_ci_passed_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.ci\.passed\z}, topic) do
      [_, number] -> {:ok, number}
      _ -> :nomatch
    end
  end

  @spec parse_pause_request_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_pause_request_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.agent\.pause\.request\z}, topic) do
      [_, identifier] -> {:ok, identifier}
      _ -> :nomatch
    end
  end

  @spec parse_branch_push_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_branch_push_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.branch\.(?:push|force-push)\z}, topic) do
      [_, identifier] -> {:ok, identifier}
      _ -> :nomatch
    end
  end

  @spec parse_agent_unblocked_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_agent_unblocked_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.agent\.unblocked\z}, topic) do
      [_, identifier] -> {:ok, identifier}
      _ -> :nomatch
    end
  end

  @spec parse_system_branch_push_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_system_branch_push_topic(topic) do
    case Regex.run(~r{\Asystem\.([^.]+)\.branch\.push\z}, topic) do
      [_, branch] -> {:ok, branch}
      _ -> :nomatch
    end
  end

  # Single-pass topic classifier: runs each parser at most once and
  # returns a tagged tuple the caller pattern-matches on. Cheaper than
  # a `cond` that calls every parser twice (once for the match? test,
  # once to extract the identifier).
  @spec classify_event_topic(String.t()) :: {atom(), String.t()} | :nomatch
  def classify_event_topic(topic) do
    with :nomatch <- tag_topic(:pr_review_comment, parse_pr_review_comment_topic(topic)),
         :nomatch <- tag_topic(:optimistic_blocker_changed, parse_optimistic_blocker_topic(topic)),
         :nomatch <- tag_topic(:issue_commented, parse_issue_commented_topic(topic)),
         :nomatch <- tag_topic(:pr_merged, parse_pr_merged_topic(topic)),
         :nomatch <- tag_topic(:ci_failed, parse_ci_failed_topic(topic)),
         :nomatch <- tag_topic(:ci_passed, parse_ci_passed_topic(topic)),
         :nomatch <- tag_topic(:pause_request, parse_pause_request_topic(topic)),
         :nomatch <- tag_topic(:decision_answered, parse_decision_answered_topic(topic)),
         :nomatch <- tag_topic(:agent_unblocked, parse_agent_unblocked_topic(topic)),
         :nomatch <- tag_topic(:optimistic_integrated, parse_optimistic_integrated_topic(topic)),
         :nomatch <- tag_topic(:branch_push, parse_branch_push_topic(topic)) do
      tag_topic(:system_branch_push, parse_system_branch_push_topic(topic))
    end
  end

  @spec parse_optimistic_blocker_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_optimistic_blocker_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.pr\.(?:closed_unmerged|reopened|opened)\z}, topic) do
      [_, identifier] -> {:ok, identifier}
      _ -> :nomatch
    end
  end

  @spec parse_optimistic_integrated_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_optimistic_integrated_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.optimistic\.integrated\z}, topic) do
      [_, identifier] -> {:ok, identifier}
      _ -> :nomatch
    end
  end

  @spec parse_decision_answered_topic(String.t()) :: {:ok, String.t()} | :nomatch
  def parse_decision_answered_topic(topic) do
    case Regex.run(~r{\Aticket\.([^.]+)\.agent\.decision\.answered\z}, topic) do
      [_, identifier] -> {:ok, identifier}
      _ -> :nomatch
    end
  end

  @spec tag_topic(atom(), {:ok, String.t()} | :nomatch) :: {atom(), String.t()} | :nomatch
  def tag_topic(tag, {:ok, identifier}), do: {tag, identifier}
  def tag_topic(_tag, :nomatch), do: :nomatch
end
