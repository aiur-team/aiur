defmodule Aiur.Orchestrator.IssueSync.StrandedTickets do
  @moduledoc """
  Requeues abandoned claims while respecting deliberate parking and external waits.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.IssueSync.LabelWrites
  alias Aiur.Orchestrator.IssueSync.MissingLabels
  alias Aiur.Orchestrator.IssueSync.TransitionAlerts
  alias Aiur.Orchestrator.Lifecycle
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks

  @doc """
  Re-queues open non-terminal tickets that have neither a live owner nor a
  scheduled claim (#2420, #2361).

  A label-integrity sweep cannot see the stranding shape behind #2361: a ticket
  carrying one perfectly valid `agent:*` state label, open, not contradictory,
  with no running agent and nothing scheduled to give it one. Its claim was
  released on a transient tracker fault and no recovery was ever scheduled, so
  it sits in `state.running`-less limbo while GitHub and `aiur status` read it
  as healthy work in progress.

  Runs after `dispatch_or_hold/2` so a ticket legitimately queued for a free
  slot is never mistaken for a strand. A ticket is stranded when it is open and
  non-terminal and has no live owner (`running`), no in-flight claim
  (`claimed`), no pending retry (`retry_attempts`), no scheduled transient
  resume (`auto_resume`), and no legitimate reason to be unowned (operator
  pause, an explicit `needs-triage`/`human:todo`/`Epic:`/`parked` marker,
  dependency block, an external wait such as CI/review/error, or a `todo`
  ticket waiting for capacity) — while its claim has been explicitly released
  (`released_claims`) or it is a degenerate zero-label ticket dispatch cannot
  claim. The repair is evidence-gated, never shape-gated: a ticket that has
  never entered the agent workflow (no running entry, no released claim, no
  prior polled state) is untriaged parking and is left alone (#2420).

  Re-queuing restores the ticket to its last known running state (falling back
  to `agent:todo`, matching the zero-label heal), writes it through the tracker,
  drops the released-claim record so the strand is not re-flagged every poll,
  and raises a needs-attention alert. The dispatch pass then claims the ticket
  like any other fresh work.
  """
  @spec sync_stranded_ticket_reconciliation(State.t(), list()) :: State.t()
  def sync_stranded_ticket_reconciliation(%State{} = state, issues) when is_list(issues) do
    sync_stranded_ticket_reconciliation(state, issues, LabelWrites.guarded_update_fun(issues))
  end

  @doc false
  @spec sync_stranded_ticket_reconciliation(State.t(), list(), (String.t(), String.t() ->
                                                                  :ok | {:error, term()})) ::
          State.t()
  def sync_stranded_ticket_reconciliation(%State{} = state, issues, update_state_fun)
      when is_list(issues) and is_function(update_state_fun, 2) do
    Enum.reduce(issues, state, fn issue, state_acc ->
      if stranded_ticket?(state_acc, issue) do
        requeue_stranded_ticket(state_acc, issue, update_state_fun)
      else
        state_acc
      end
    end)
  end

  def sync_stranded_ticket_reconciliation(%State{} = state, _issues, _update_state_fun), do: state

  defp stranded_ticket?(%State{} = state, %Issue{id: issue_id} = issue) do
    cond do
      owned_or_scheduled?(state, issue_id) ->
        false

      legitimately_unowned?(issue) ->
        false

      # A ticket that has never entered the agent workflow (no running entry,
      # no released claim, no prior polled state) is untriaged parking, not a
      # strand: nothing removed its label, it just never had one. The repair
      # must be evidence-gated, not shape-gated (#2420).
      not MissingLabels.workflow_evidence?(state, issue) ->
        false

      stranded_by_claim_or_labels?(state, issue) ->
        true

      true ->
        false
    end
  end

  defp stranded_ticket?(_state, _issue), do: false

  # A live owner, an in-flight claim, a pending retry, or a scheduled transient
  # resume means the ticket has someone (or something) responsible for it, so a
  # missing live agent is not a strand.
  @doc false
  @spec owned_or_scheduled?(State.t(), String.t()) :: boolean()
  def owned_or_scheduled?(%State{} = state, issue_id) do
    Map.has_key?(state.running, issue_id) or
      MapSet.member?(state.claimed, issue_id) or
      Map.has_key?(state.retry_attempts, issue_id) or
      Map.has_key?(state.auto_resume, issue_id) or
      TrackerTasks.issue_pending?(state, issue_id)
  end

  # States where an open ticket is deliberately unowned need no claim: an
  # operator park, pause, or queue marker, a dependency or capacity wait, an external
  # wait (CI/review/error), or a `todo` ticket waiting for a free slot. A
  # ticket carrying `needs-triage`/`human:todo`/`Epic:` is deliberate parking,
  # never a strand, so it is covered here too (#2420).
  defp legitimately_unowned?(%Issue{} = issue) do
    Issue.held?(issue) or
      Issue.paused?(issue) or
      Issue.parked?(issue) or
      Issue.queued?(issue) or
      MissingLabels.parked_marker?(issue) or
      DispatchPolicy.issue_held_by_dependency?(issue, DispatchPolicy.terminal_state_set()) or
      external_wait_state?(issue) or
      DispatchPolicy.normalize_issue_state(issue.state) == "todo"
  end

  # The two strand shapes label checks cannot see. A released claim with no
  # recovery scheduled is a valid state label, no owner, and nothing scheduled
  # to give it one (#2361); a dispatch latch or thrash hold on the same ticket
  # still leaves the released claim unresolved, so re-queueing remains correct.
  # An open ticket with no derivable state at all (zero state labels) is
  # invisible to dispatch and has no legitimate wait reason; the zero-label
  # heal normally restores it earlier in the poll, and this is the sweep's own
  # fallback so the invariant holds even if that write fails. Both shapes only
  # reach this predicate after `stranded_ticket?/2`'s evidence gate, so an
  # unprovenanced zero-label ticket is never re-queued (#2420).
  defp stranded_by_claim_or_labels?(%State{} = state, %Issue{} = issue) do
    Map.has_key?(state.released_claims, issue.id) or
      DispatchPolicy.normalize_issue_state(issue.state) == ""
  end

  # A stranded ticket's owner evaporated without a scheduled replacement, so the
  # work is stale: restore it to a dispatchable state (its last known running
  # state, else `agent:todo`) exactly like the zero-label heal, so the next
  # dispatch pass claims it as fresh work. A failed restore keeps the
  # released-claim record so the strand stays visible to the operator.
  defp requeue_stranded_ticket(%State{} = state, %Issue{} = issue, update_state_fun) do
    restored = MissingLabels.restore_state_for(issue, state)
    input = Reconciler.issue_input(state, issue.id)

    TrackerTasks.run(
      state,
      {:stranded_repair, issue.id},
      fn -> update_state_fun.(issue.identifier, restored) end,
      fn current, result ->
        if Reconciler.issue_input(current, issue.id) == input and stranded_ticket?(current, issue) do
          apply_stranded_repair(current, issue, restored, result)
        else
          Lifecycle.wake_tick(current)
        end
      end
    )
  end

  defp apply_stranded_repair(state, issue, restored, result) do
    case result do
      :ok ->
        state = alert_stranded_ticket_requeued(state, issue, restored, label_state_changed?(issue, restored))

        Logger.warning("Re-queueing stranded ticket #{State.issue_context(issue)} -> #{restored}")

        %{
          state
          | released_claims: Map.delete(state.released_claims, issue.id)
        }

      {:error, reason} ->
        Logger.warning("Stranded ticket re-queue failed for #{State.issue_context(issue)}: #{inspect(reason)}")

        alert_stranded_ticket_requeue_failed(state, issue, restored, reason)
    end
  end

  # A stranded ticket is surfaced with a needs-attention alert; the check
  # against the already-active attention set keeps a ticket that fails its
  # restore from alerting on every poll.
  defp alert_stranded_ticket_requeued(%State{} = state, %Issue{} = issue, restored, changed?) do
    topic = "ticket.#{issue.identifier}.agent.attention.stranded-requeued"

    {message, reason} =
      if changed? do
        {
          "Ticket #{issue.identifier} was open with no live agent and no scheduled claim; re-queued to #{restored}.",
          "Ticket #{issue.identifier} had no live owner and no scheduled claim; restored #{restored} so dispatch can claim it again."
        }
      else
        {
          "Ticket #{issue.identifier} was already in #{restored}; its abandoned claim was cleared for dispatch.",
          "Ticket #{issue.identifier} already had the #{restored} state label; no label change was needed to clear the abandoned claim."
        }
      end

    unless TransitionAlerts.active_attention?(state, topic) do
      Alerts.emit_system(topic,
        issue: issue.identifier,
        message: message,
        reason: reason,
        needs_attention: true,
        severity: "warning",
        central: true
      )
    end

    state
  end

  defp label_state_changed?(%Issue{state_labels: labels}, restored) when is_list(labels) do
    labels |> Enum.map(&DispatchPolicy.normalize_state_label/1) |> Enum.reject(&(&1 == "")) != [DispatchPolicy.normalize_state_label(restored)]
  end

  defp label_state_changed?(%Issue{state: current}, restored) do
    DispatchPolicy.normalize_state_label(current) != DispatchPolicy.normalize_state_label(restored)
  end

  defp alert_stranded_ticket_requeue_failed(%State{} = state, %Issue{} = issue, restored, reason) do
    topic = "ticket.#{issue.identifier}.agent.attention.stranded-requeue-failed"

    unless TransitionAlerts.active_attention?(state, topic) do
      Alerts.emit_system(topic,
        issue: issue.identifier,
        message: "Ticket #{issue.identifier} could not be re-queued to #{restored}.",
        reason: "The tracker rejected the stranded-ticket state restore: #{inspect(reason)}.",
        needs_attention: true,
        severity: "warning",
        central: true
      )
    end

    state
  end

  # States where an open ticket is deliberately waiting on something external
  # (CI, human review, or an operator/error recovery) need no agent claim, so a
  # lack of one is not a strand.
  defp external_wait_state?(%Issue{} = issue) do
    DispatchPolicy.normalize_issue_state(issue.state) in ["ci-wait", "human-review", "error", "merging"] or
      Enum.any?(issue.state_labels || [], fn label ->
        normalized = DispatchPolicy.normalize_issue_state(label)
        normalized in ["ci-wait", "human-review", "error", "merging"]
      end)
  end
end
