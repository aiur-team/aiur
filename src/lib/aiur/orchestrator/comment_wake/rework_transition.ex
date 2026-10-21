defmodule Aiur.Orchestrator.CommentWake.ReworkTransition do
  @moduledoc "Asynchronous review gates and bounded rework state writes."

  alias Aiur.Orchestrator.CommentWake
  alias Aiur.Orchestrator.CommentWake.ReworkRetries
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.ReviewFindings
  alias Aiur.Orchestrator.ReviewFreshness
  alias Aiur.Orchestrator.ReworkGate
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.Signal

  @doc false
  @spec with_comment_transition(State.t(), String.t() | integer(), String.t() | integer(), String.t() | atom(), map(), term(), pos_integer(), function()) :: State.t()
  def with_comment_transition(state, issue_key, telemetry_ticket, source, event, attempt_id, attempt, continuation) do
    entry = State.find_running_by_identifier(state.running, telemetry_ticket)

    TrackerTasks.run(state, {:comment_gate, issue_key, source, make_ref()}, fn -> comment_rework_gate(issue_key, event) end, fn current, result ->
      if TrackerTasks.same_runner?(State.find_running_by_identifier(current.running, telemetry_ticket), entry) do
        apply_comment_gate(current, result, %{
          issue_key: issue_key,
          ticket: telemetry_ticket,
          source: source,
          event: event,
          attempt_id: attempt_id,
          attempt: attempt,
          entry: entry,
          continuation: continuation
        })
      else
        current
      end
    end)
  end

  defp comment_write_pending?(state, issue_key) do
    Enum.any?(state.tracker_tasks, fn
      {_ref, %{key: {:comment_write, key, _source, _event}}} -> to_string(key) == to_string(issue_key)
      _ -> false
    end)
  end

  defp comment_rework_gate(issue_key, event) do
    cond do
      not CommentWake.trusted_comment_event?(event) -> {:skip, :untrusted_author}
      CommentWake.benign_review_pass_comment?(event) -> {:skip, :benign_review_pass_comment}
      reason = ReviewFreshness.rework_skip_reason(event) -> {:skip, reason}
      true -> ReworkGate.verify_unresolved_review_threads(issue_key, rework_threads_opts(event))
    end
  end

  defp apply_comment_gate(state, {:ok, pr}, context) do
    head_sha = ReworkGate.head_sha(pr)

    if comment_write_pending?(state, context.issue_key) do
      state
      |> OperatorMessages.enqueue_event_digest_item(to_string(context.ticket), [context.event], context.event)
      |> ReworkRetries.schedule_comment_rework_retry(context.ticket, context.source, context.event, context.attempt, :rework_write_in_progress)
    else
      start_comment_rework(state, head_sha, context)
    end
  end

  defp apply_comment_gate(state, result, context), do: context.continuation.({result, state})

  defp start_comment_rework(state, head_sha, context) do
    identifier = to_string(context.issue_key)

    case ReworkGate.verify_rework_attempt(state, identifier, head_sha, rework_attempt_alert_opts(context.event)) do
      {:ok, state} ->
        TrackerTasks.run(
          state,
          {:comment_write, context.issue_key, context.source, make_ref()},
          fn -> write_comment_rework(context.issue_key, context.ticket, context.source, context.event, context.attempt_id) end,
          fn current, written -> apply_comment_rework_write(current, written, {context.continuation, context.entry, head_sha, identifier, context.ticket}) end
        )

      {:skip, reason, current} ->
        context.continuation.({{:skip, reason}, current})
    end
  end

  # The open-PR lookup and the unresolved-thread read are injectable via the
  # event for tests; otherwise they route through `ReworkGate`'s defaults (the
  # tracker's open-PR fetch and review-thread fetch, which fail open where no
  # PR notion exists).
  defp rework_threads_opts(event) do
    event
    |> rework_open_pr_opts()
    |> maybe_put_threads_fetcher(event)
    |> Keyword.put(:blocking_review_submission?, blocking_review_submission?(event))
  end

  # A `CHANGES_REQUESTED` or explicitly blocking `COMMENTED` review with no inline comments
  # opens no review thread, so #2422's unresolved-thread read reports nothing
  # and the ticket never leaves `agent:human-review` (#2473). The review
  # submission *is* the outstanding finding, so it is handed to the gate as an
  # equivalent signal. What stops that from re-entering #2422's rework loop is
  # that a review submission is delivered once — the `Aiur.Events` publish boundary drops
  # a redelivery on the durable `{:pr_review, …}` resource identity before it
  # ever reaches the gate — NOT `ReviewFreshness`, whose staleness half is
  # inert on webhook deliveries. `ReworkGate`'s `no_thread_verdict/1` carries
  # the full argument; read it there before changing this.
  #
  # Both publishers put the review under `comment` with an upper-cased `state`
  # — `GithubCommentsPoller.publish_pr_review_submission/5` reads REST
  # `/reviews`, which reports upper case, and the webhook pipe's
  # `Normalizer.review_submission_triple/3` applies `upcase_review_state/1` to
  # a delivery's lower-cased state — so one derivation covers the delivery path
  # and its polling backstop. The fold below is what makes that agreement a
  # property of this function rather than of its two producers.
  #
  # Event payloads reach the orchestrator with atom keys from an in-process
  # publish and string keys after a JSON round trip through the event store,
  # so both shapes are read, exactly as `CommentWake.comment_body/1` does.
  #
  # No non-map clause: the caller is what guarantees the map. `rework_threads_opts/1`
  # pipes the event through `rework_open_pr_opts/1` first, which reads it with
  # `Map.get/2`, so a non-map event raises there before reaching this function —
  # the same reason the two sibling helpers below carry no such clause either.
  defp blocking_review_submission?(event) do
    case {comment_review_state(event), CommentWake.comment_body(event)} do
      {state, body} when is_binary(state) ->
        String.upcase(state) == "CHANGES_REQUESTED" or
          (String.upcase(state) == "COMMENTED" and ReviewFindings.blocking_body?(body))

      _other ->
        false
    end
  end

  @doc false
  @spec changes_requested_review?(map()) :: boolean()
  def changes_requested_review?(event) do
    case comment_review_state(event) do
      state when is_binary(state) -> String.upcase(state) == "CHANGES_REQUESTED"
      _other -> false
    end
  end

  defp comment_review_state(event) do
    comment = Map.get(event, :comment) || Map.get(event, "comment") || %{}

    if is_map(comment) do
      Map.get(comment, :state) || Map.get(comment, "state")
    end
  end

  defp rework_open_pr_opts(event) do
    case Map.get(event, :open_pr_fetcher) do
      fun when is_function(fun, 1) -> [open_pr_fetcher: fun]
      _ -> []
    end
  end

  defp maybe_put_threads_fetcher(opts, event) do
    case Map.get(event, :unresolved_threads_fetcher) do
      fun when is_function(fun, 1) -> Keyword.put(opts, :unresolved_threads_fetcher, fun)
      _ -> opts
    end
  end

  # The rework-attempt attention's emitter is injectable for tests; production
  # routes through `Aiur.Alerts.emit_system/2`.
  defp rework_attempt_alert_opts(event) do
    case Map.get(event, :emit_alert_fun) do
      fun when is_function(fun, 2) -> [emit_alert_fun: fun]
      _ -> []
    end
  end

  defp write_comment_rework(issue_key, telemetry_ticket, source, event, attempt_id) do
    update_issue_state_fun = Map.get(event, :comment_update_issue_state_fun, &TicketTransition.write_state(&1, &2, writer: :comment_wake))

    case update_issue_state_fun.(to_string(issue_key), "rework") do
      :ok ->
        Signal.lifecycle(
          to_string(telemetry_ticket),
          attempt_id,
          :rework_start,
          :point,
          %{source: source, outcome: :success}
        )

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_comment_rework_write(
         current,
         written,
         {continuation, entry, head_sha, identifier, ticket}
       ) do
    if TrackerTasks.same_runner?(State.find_running_by_identifier(current.running, ticket), entry) do
      case written do
        :ok -> continuation.({:ok, State.bump_rework_attempt(current, identifier, head_sha)})
        {:error, _} = error -> continuation.({error, current})
      end
    else
      current
    end
  end
end
