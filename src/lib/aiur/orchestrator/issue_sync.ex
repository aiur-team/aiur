defmodule Aiur.Orchestrator.IssueSync do
  @moduledoc """
  Synchronizes polled issues into orchestrator state and derived events.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{AgentQueue, AgentQueueStore, AlertFeed, Alerts, CodingAgent, Config, CurrentRunMembership, DispatchBudgetStore, Issue, Tracker, TrackerIdentity}
  alias Aiur.Config.Paths
  alias Aiur.GitHub.StatePolicy
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{AutoSubscriptions, DispatchPolicy, MembershipLifecycle, OperatorMessages, PushRouting, Reconciler, Slots, State}
  alias Aiur.PollCadence

  @idle_terminal_verification_batch_size 25
  @capacity_starvation_alert_after_ms 60_000
  # A contradictory-label pair must persist this long (about one poll cycle)
  # before the single fleet alert fires, so a pair the heal repairs on the same
  # observation never alarms.
  @contradictory_label_alert_after_ms 60_000

  @spec sync_polled_issue_state(State.t(), list()) :: State.t()
  def sync_polled_issue_state(%State{} = state, issues) when is_list(issues) do
    sync_polled_issue_state(
      state,
      issues,
      &Tracker.fetch_issue_states_by_ids/1,
      &MembershipLifecycle.observe/2,
      DispatchPolicy.terminal_state_set(),
      &CurrentRunMembership.mark_reconciled/1
    )
  end

  def sync_polled_issue_state(%State{} = state, _issues), do: state

  @doc """
  Heals polled issues that observe more than one `agent:*` state label.

  A ticket carrying both `agent:todo` and `agent:rework` is a broken lifecycle
  state: the dispatch guard used to refuse it, silently dropping the ticket
  from every poll with no error and no alert (#2075). This resolves the pair
  deterministically via `DispatchPolicy.resolve_state_labels/1` (`todo` wins —
  a ticket that is also `todo` has no work for a `rework` verdict to mean
  anything about), writes the winner through the tracker so GitHub stops
  carrying both labels, and logs the resolution. Transient write failures keep
  the resolved issue in the returned list so the ticket is still dispatchable
  this cycle; the next poll retries the heal.

  Returns `{state, healed_issues}` so the caller dispatches against the healed
  view and stores the healed copies in `last_polled_issues`.
  """
  @spec reconcile_contradictory_state_labels(State.t(), list()) :: {State.t(), list()}
  def reconcile_contradictory_state_labels(%State{} = state, issues) when is_list(issues) do
    reconcile_contradictory_state_labels(state, issues, &Tracker.update_issue_state/2)
  end

  @doc false
  @spec reconcile_contradictory_state_labels(State.t(), list(), (String.t(), String.t() -> :ok | {:error, term()})) ::
          {State.t(), list()}
  def reconcile_contradictory_state_labels(%State{} = state, issues, update_state_fun)
      when is_list(issues) and is_function(update_state_fun, 2) do
    previous_tickets = state.contradictory_state_label_tickets
    now_ms = System.monotonic_time(:millisecond)

    {healed_issues, state} =
      Enum.reduce(issues, {[], state}, fn issue, {acc, state_acc} ->
        case issue do
          %Issue{state_labels: [_, _ | _] = state_labels} = issue ->
            {healed_issue, state_acc} = heal_contradictory_state(issue, winner_for(state_labels), state_acc, update_state_fun)
            {[healed_issue | acc], state_acc}

          # `state_labels == []` is the GitHub normalizer's zero-label signal
          # (state is nil alongside it); `state_labels == nil` with no state is
          # the not-normalized equivalent. An issue that carries a real state
          # without a populated labels list (e.g. non-GitHub tracker fixtures)
          # is not a stranded zero-label ticket and is left untouched, and a
          # closed issue needs no state label at all (#2420).
          %Issue{state_labels: state_labels, state: state} = issue
          when (state_labels == [] or (state_labels == nil and is_nil(state))) and state != "Closed" ->
            {healed_issue, state_acc} = heal_or_leave_missing_state_label(issue, state_acc, update_state_fun)
            {[healed_issue | acc], state_acc}

          _issue ->
            {[issue | acc], state_acc}
        end
      end)

    tickets = contradictory_state_label_tickets(issues, previous_tickets, now_ms)
    state = sync_contradictory_state_label_alert(state, tickets, now_ms)

    {state, Enum.reverse(healed_issues)}
  end

  def reconcile_contradictory_state_labels(%State{} = state, _issues, _update_state_fun), do: {state, []}

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
    sync_stranded_ticket_reconciliation(state, issues, &Tracker.update_issue_state/2)
  end

  @doc false
  @spec sync_stranded_ticket_reconciliation(State.t(), list(), (String.t(), String.t() -> :ok | {:error, term()})) ::
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
      not workflow_evidence?(state, issue) ->
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
  defp owned_or_scheduled?(%State{} = state, issue_id) do
    Map.has_key?(state.running, issue_id) or
      MapSet.member?(state.claimed, issue_id) or
      Map.has_key?(state.retry_attempts, issue_id) or
      Map.has_key?(state.auto_resume, issue_id)
  end

  # States where an open ticket is deliberately unowned need no claim: an
  # operator park or pause marker, a dependency or capacity wait, an external
  # wait (CI/review/error), or a `todo` ticket waiting for a free slot. A
  # ticket carrying `needs-triage`/`human:todo`/`Epic:` is deliberate parking,
  # never a strand, so it is covered here too (#2420).
  defp legitimately_unowned?(%Issue{} = issue) do
    Issue.paused?(issue) or
      Issue.parked?(issue) or
      parked_marker?(issue) or
      DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, DispatchPolicy.terminal_state_set()) or
      external_wait_state?(issue.state) or
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
    restored = restore_state_for(issue, state)

    case update_state_fun.(issue.identifier, restored) do
      :ok ->
        alert_stranded_ticket_requeued(state, issue, restored)

        Logger.warning("Re-queueing stranded ticket #{State.issue_context(issue)} -> #{restored}")

        %{state | released_claims: Map.delete(state.released_claims, issue.id)}

      {:error, reason} ->
        Logger.warning("Stranded ticket re-queue failed for #{State.issue_context(issue)}: #{inspect(reason)}")

        state
    end
  end

  # A stranded ticket is surfaced with a needs-attention alert; the check
  # against the already-active attention set keeps a ticket that fails its
  # restore from alerting on every poll.
  defp alert_stranded_ticket_requeued(%State{} = state, %Issue{} = issue, restored) do
    topic = "ticket.#{issue.identifier}.agent.attention.stranded-requeued"

    unless active_attention?(state, topic) do
      Alerts.emit_system(topic,
        issue: issue.identifier,
        message: "Ticket #{issue.identifier} was open with no live agent and no scheduled claim; re-queued to #{restored}.",
        reason:
          "Ticket #{issue.identifier} had no live owner and no scheduled claim (a released claim or degenerate label set); " <>
            "restored #{restored} so dispatch can claim it again.",
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
  defp external_wait_state?(state_name) do
    DispatchPolicy.normalize_issue_state(state_name) in ["ci-wait", "human-review", "error"]
  end

  defp winner_for(state_labels), do: DispatchPolicy.resolve_state_labels(state_labels)

  # A ticket observed with zero `agent:*` state labels is invisible to dispatch
  # (#2420): every reconciler consumes either the filtered candidate list or
  # `state.running`, and a zero-label ticket is in neither, so nothing would
  # ever repair a genuine strand. But zero labels is *also* a documented,
  # intentional state — deliberately parked work carries `needs-triage`,
  # `human:todo`, or an `Epic:` marker with no state label, and a fresh issue
  # nobody has triaged has neither — so the repair must be evidence-gated, not
  # shape-gated: never touch a parked-marker ticket, restore the last known
  # state only when a prior running/last-polled entry carries one, and when
  # there is no evidence at all alert without writing and leave the labels
  # alone (#2420).
  defp heal_or_leave_missing_state_label(%Issue{} = issue, state, update_state_fun) do
    cond do
      Issue.parked?(issue) or parked_marker?(issue) ->
        {issue, state}

      restore_target_for(issue, state) == nil and not workflow_evidence?(state, issue) ->
        alert_missing_state_label_no_evidence(issue, state)
        {issue, state}

      restore_target_for(issue, state) == nil ->
        # Evidence of workflow membership exists (e.g. a released claim) but
        # there is no non-terminal state to restore; leave the ticket for the
        # sweep, whose re-queue falls back to `agent:todo`.
        {issue, state}

      true ->
        heal_missing_state_label(issue, state, update_state_fun)
    end
  end

  defp heal_missing_state_label(%Issue{} = issue, state, update_state_fun) do
    restored = restore_target_for(issue, state) || "todo"
    healed_issue = %{issue | state: restored, state_labels: [restored]}

    case update_state_fun.(issue.identifier, restored) do
      :ok ->
        alert_missing_state_label_repaired(issue, restored)

        Logger.warning("Healing missing state label for #{State.issue_context(issue)} -> #{restored}")

        {healed_issue, %{state | last_polled_issues: Map.put(state.last_polled_issues, issue.id, healed_issue)}}

      {:error, reason} ->
        Logger.warning("Missing state label heal failed for #{State.issue_context(issue)}: #{inspect(reason)}; dispatching on restored state")

        {healed_issue, state}
    end
  end

  # The last known state comes from the running entry's issue (the state its
  # agent was last dispatched under) or the previous polled copy. A running
  # entry is authoritative; the previous poll is the fallback so a swap that
  # removed the label between polls still restores the pre-transition state.
  defp prior_workflow_state(%Issue{id: issue_id}, %State{} = state) do
    workflow_state_from(Map.get(state.running, issue_id)) ||
      workflow_state_from(Map.get(state.last_polled_issues, issue_id))
  end

  defp prior_workflow_state(_issue, _state), do: nil

  # A non-empty state name from a running entry (`%{issue: %Issue{}}` or
  # `%{issue: %{}}`) or a prior polled copy (`%Issue{}` or `%{}`). Running
  # entries wrap the issue under `:issue`; a polled copy is the issue itself.
  defp workflow_state_from(%{issue: issue}) when is_map(issue), do: workflow_state_from(issue)
  defp workflow_state_from(%Issue{state: state_name}) when is_binary(state_name) and state_name != "", do: state_name
  defp workflow_state_from(%{state: state_name}) when is_binary(state_name) and state_name != "", do: state_name
  defp workflow_state_from(_entry), do: nil

  # The state to restore a stranded ticket to. Only a non-terminal state is a
  # safe restore target; a terminal prior state (or no prior state at all)
  # yields nil so the caller alerts without writing rather than guessing.
  defp restore_target_for(%Issue{} = issue, %State{} = state) do
    case prior_workflow_state(issue, state) do
      nil -> nil
      state_name -> if StatePolicy.terminal_state_name?(state_name), do: nil, else: state_name
    end
  end

  # The sweep's restore target: a non-terminal prior state when one exists,
  # else `agent:todo`. The sweep only re-queues a ticket after its own
  # evidence gate (`workflow_evidence?/2`) has passed, so `todo` here is a
  # documented fallback for a ticket whose workflow record is a released claim
  # rather than a running/last-polled state (#2420).
  defp restore_state_for(%Issue{} = issue, %State{} = state) do
    restore_target_for(issue, state) || "todo"
  end

  # Positive evidence the ticket was in the agent workflow: a live running
  # entry, a released claim (a claim was dropped), or a prior polled copy
  # carrying a state. A ticket with none of these has never entered the
  # workflow and is untriaged parking, not a strand (#2420).
  defp workflow_evidence?(%State{} = state, %Issue{id: issue_id} = issue) do
    Map.has_key?(state.running, issue_id) or
      Map.has_key?(state.released_claims, issue_id) or
      is_binary(prior_workflow_state(issue, state))
  end

  # Deliberately parked work carries a non-state marker instead of an `agent:*`
  # state label — `needs-triage`, `human:todo`, or an `Epic:` container (the
  # explicit `agent:parked` marker is surfaced separately as `Issue.parked?`).
  # Such tickets must never be rewritten to `agent:todo`: that would silently
  # reverse deliberate parking and make `human:todo` tickets dispatchable, the
  # exact boundary that label protects (#2420).
  defp parked_marker?(%Issue{labels: labels}) do
    Enum.any?(labels, &parked_marker_label?/1)
  end

  defp parked_marker_label?(label) when is_binary(label) do
    label = label |> String.trim() |> String.downcase()
    label in ["needs-triage", "human:todo"] or String.starts_with?(label, "epic:")
  end

  defp parked_marker_label?(_label), do: false

  # A zero-label ticket with no prior workflow record is surfaced with a
  # needs-attention alert but NOT rewritten: stamping `agent:todo` on a ticket
  # whose history shows no prior state is a guess that would reverse deliberate
  # parking (#2420). The active-attention check keeps the alert to one per
  # ticket instead of one per poll.
  defp alert_missing_state_label_no_evidence(%Issue{} = issue, %State{} = state) do
    topic = "ticket.#{issue.identifier}.agent.attention.state-label-missing-no-evidence"

    unless active_attention?(state, topic) do
      Alerts.emit_system(topic,
        issue: issue.identifier,
        message:
          "Ticket #{issue.identifier} has no agent state label and no record of prior agent workflow membership; " <>
            "left as-is pending triage.",
        reason:
          "Ticket #{issue.identifier} carries zero agent:* state labels with no prior running/last-known state and no " <>
            "parking marker; left as-is pending triage — alerting without writing agent:todo so deliberate parking is not " <>
            "reversed (#2420).",
        needs_attention: true,
        severity: "warning",
        central: true
      )
    end
  end

  defp alert_missing_state_label_repaired(%Issue{} = issue, restored) do
    Alerts.emit_system("ticket.#{issue.identifier}.agent.attention.state-label-missing",
      issue: issue.identifier,
      message: "Ticket #{issue.identifier} had no agent state label and was invisible to dispatch; repaired to #{restored}.",
      reason:
        "Ticket #{issue.identifier} carried zero agent:* state labels (a broken remove-then-add swap left it stranded); " <>
          "restored #{restored} so dispatch can see it again.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end

  # Collects the polled tickets that carry more than one `agent:*` state label —
  # the fleet that dispatch authorization denies as ambiguous (#2366). `since_ms`
  # carries over from the previous poll so the fleet alert only fires once a pair
  # has persisted past the debounce, and only while it is still undispatchable.
  defp contradictory_state_label_tickets(issues, previous, now_ms) do
    Enum.reduce(issues, %{}, fn
      %Issue{id: id, identifier: identifier, state_labels: [_, _ | _] = labels}, acc
      when is_binary(id) and is_binary(identifier) ->
        previous_entry = Map.get(previous, id)
        since_ms = if is_map(previous_entry) and is_integer(previous_entry.since_ms), do: previous_entry.since_ms, else: now_ms

        Map.put(acc, id, %{identifier: identifier, labels: labels, since_ms: since_ms})

      _issue, acc ->
        acc
    end)
  end

  # One fleet-level line instead of one buried warning per ticket: a ticket whose
  # contradictory labels make it undispatchable is exactly the silent-by-
  # construction failure that needs needs-attention prominence (#2366). Emitted
  # once the same pair has persisted past the debounce; resolved when the set
  # clears (healed, or transitioned to a single label).
  defp sync_contradictory_state_label_alert(%State{} = state, tickets, now_ms) do
    persisted? =
      Enum.any?(tickets, fn {_id, entry} -> now_ms - entry.since_ms >= @contradictory_label_alert_after_ms end)

    cond do
      map_size(tickets) > 0 and not state.contradictory_state_label_alert_active and persisted? ->
        emit_contradictory_state_label_alert(state, tickets)

      map_size(tickets) == 0 and state.contradictory_state_label_alert_active ->
        resolve_contradictory_state_label_alert(state)

      true ->
        %{state | contradictory_state_label_tickets: tickets}
    end
  end

  defp emit_contradictory_state_label_alert(%State{} = state, tickets) do
    identifiers = tickets |> Map.values() |> Enum.map(& &1.identifier) |> Enum.sort()

    message =
      "#{length(identifiers)} ticket#{if length(identifiers) == 1, do: "", else: "s"} undispatchable due to contradictory labels: " <>
        Enum.join(identifiers, ", ")

    case Alerts.emit_system("system.fleet.contradictory_state_labels",
           message: message,
           reason:
             message <>
               ". A ticket carrying more than one agent:* state label cannot be dispatched; the next state transition replaces the set. Run the audit from #2366 and clear the extra label if the heal did not.",
           needs_attention: true,
           severity: "warning"
         ) do
      :ok ->
        %{state | contradictory_state_label_tickets: tickets, contradictory_state_label_alert_active: true}

      {:error, reason} ->
        Logger.warning("Contradictory state label alert emission failed: reason=#{inspect(reason)}")
        %{state | contradictory_state_label_tickets: tickets}
    end
  end

  defp resolve_contradictory_state_label_alert(%State{} = state) do
    message = "No tickets undispatchable due to contradictory labels"

    Alerts.emit_system("system.fleet.contradictory_state_labels.resolved",
      message: message,
      reason: message <> ". Every ticket now carries exactly one agent:* state label.",
      needs_attention: false,
      severity: "info"
    )

    %{state | contradictory_state_label_tickets: %{}, contradictory_state_label_alert_active: false}
  end

  defp heal_contradictory_state(%Issue{} = issue, winner, state, update_state_fun) do
    healed_issue = %{issue | state: winner, state_labels: [winner]}

    case update_state_fun.(issue.identifier, winner) do
      :ok ->
        Logger.warning("Healing contradictory state labels for #{State.issue_context(issue)} labels=#{inspect(issue.state_labels)} -> #{winner}")

        {healed_issue, %{state | last_polled_issues: Map.put(state.last_polled_issues, issue.id, healed_issue)}}

      {:error, reason} ->
        Logger.warning("Contradictory state label heal failed for #{State.issue_context(issue)}: #{inspect(reason)}; dispatching on resolved state")

        {healed_issue, state}
    end
  end

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term())
        ) :: State.t()
  def sync_polled_issue_state(%State{} = state, issues, fetch_issue_states_fun, observe_membership_fun)
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) do
    sync_polled_issue_state(
      state,
      issues,
      fetch_issue_states_fun,
      observe_membership_fun,
      DispatchPolicy.terminal_state_set()
    )
  end

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term()),
          MapSet.t()
        ) :: State.t()
  def sync_polled_issue_state(
        %State{} = state,
        issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states
      )
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) and
             is_struct(terminal_states, MapSet) do
    sync_polled_issue_state(
      state,
      issues,
      fetch_issue_states_fun,
      observe_membership_fun,
      terminal_states,
      &CurrentRunMembership.mark_reconciled/1,
      &CurrentRunMembership.set_terminal_verification_pending/2
    )
  end

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term()),
          MapSet.t(),
          (:fresh | :unavailable -> term())
        ) :: State.t()
  def sync_polled_issue_state(
        %State{} = state,
        issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        mark_reconciled_fun
      )
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) and
             is_struct(terminal_states, MapSet) and is_function(mark_reconciled_fun, 1) do
    sync_polled_issue_state(
      state,
      issues,
      fetch_issue_states_fun,
      observe_membership_fun,
      terminal_states,
      mark_reconciled_fun,
      &CurrentRunMembership.set_terminal_verification_pending/2
    )
  end

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term()),
          MapSet.t(),
          (:fresh | :unavailable -> term()),
          (TrackerIdentity.t(), boolean() -> term())
        ) :: State.t()
  def sync_polled_issue_state(
        %State{} = state,
        issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        mark_reconciled_fun,
        set_terminal_verification_pending_fun
      )
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) and
             is_struct(terminal_states, MapSet) and is_function(mark_reconciled_fun, 1) and
             is_function(set_terminal_verification_pending_fun, 2) do
    state = %{state | active_attention_topics: active_attention_topics()}
    state = Reconciler.resolve_orphaned_divergence_attentions(state)
    previous_issues = state.last_polled_issues
    current_issues = issues_by_id(issues)

    retained_issues =
      record_disappearing_idle_terminals(
        state,
        previous_issues,
        current_issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        mark_reconciled_fun,
        set_terminal_verification_pending_fun
      )

    state =
      Enum.reduce(issues, state, fn issue, state_acc ->
        previous_issue = Map.get(previous_issues, issue.id)

        state_acc
        |> emit_task_state_transition_alert(previous_issue, issue)
        |> emit_tracker_pause_transition_alert(previous_issue, issue)
        |> emit_dependency_transition_events(previous_issue, issue)
      end)

    # `issues` is the active poll: pass it so the recheck prefers a freshly
    # polled blockee over the snapshot stored in the running entry.
    state = PushRouting.recheck_cleared_dependency_pauses(state, fetch_issue_states_fun, issues)

    %{
      state
      | last_polled_issues: retained_issues,
        released_claims: purge_resolved_released_claims(state.released_claims, retained_issues, terminal_states)
    }
  end

  # A `released_claims` entry exists only to tell the operator that a claim was
  # dropped and still needs recovery. Once the ticket reaches a terminal tracker
  # state there is nothing left to recover, and the entry becomes a permanently
  # inflated `RELEASED CLAIMS n` that an operator will chase and find nothing
  # behind. Losing one line of history is cheap; a confident wrong count is not.
  #
  # Filter against the RETAINED issues, not the raw poll. A claim is released
  # because the tracker was failing or rate-limiting us, which is exactly when a
  # poll comes back partial — and a ticket merely absent from one such poll is
  # still pending terminal verification, not gone. `retained_issues` already
  # encodes that distinction, so an entry survives until the disappearance is
  # confirmed rather than vanishing on the first bad poll (#1475).
  defp purge_resolved_released_claims(released_claims, retained_issues, terminal_states) when is_map(released_claims) do
    Map.filter(released_claims, fn {issue_id, _release} ->
      case Map.get(retained_issues, issue_id) do
        %Issue{state: issue_state} -> not DispatchPolicy.terminal_issue_state?(issue_state, terminal_states)
        _confirmed_gone -> false
      end
    end)
  end

  defp issues_by_id(issues) do
    Enum.reduce(issues, %{}, fn
      %Issue{id: issue_id} = issue, acc when is_binary(issue_id) -> Map.put(acc, issue_id, issue)
      _issue, acc -> acc
    end)
  end

  defp active_attention_topics do
    [log_roots: [Paths.log_root_dir()], needs_attention: true]
    |> AlertFeed.list()
    |> MapSet.new(& &1["topic"])
  end

  defp record_disappearing_idle_terminals(
         %State{} = state,
         previous_issues,
         current_issues,
         fetch_issue_states_fun,
         observe_membership_fun,
         terminal_states,
         mark_reconciled_fun,
         set_terminal_verification_pending_fun
       ) do
    disappearing_idle_issue_ids =
      previous_issues
      |> Map.keys()
      |> Enum.reject(fn issue_id ->
        Map.has_key?(current_issues, issue_id) or
          Map.has_key?(state.running, issue_id) or
          Map.has_key?(state.retry_attempts, issue_id)
      end)
      |> Enum.sort()

    pending_issue_ids =
      record_refreshed_terminal_membership(
        disappearing_idle_issue_ids,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        set_terminal_verification_pending_fun
      )

    retain_pending_terminal_verification(
      pending_issue_ids,
      mark_reconciled_fun,
      set_terminal_verification_pending_fun
    )

    Map.merge(current_issues, Map.take(previous_issues, pending_issue_ids))
  end

  defp record_refreshed_terminal_membership(
         [],
         _fetch_issue_states_fun,
         _observe_membership_fun,
         _terminal_states,
         _set_terminal_verification_pending_fun
       ),
       do: []

  defp record_refreshed_terminal_membership(
         issue_ids,
         fetch_issue_states_fun,
         observe_membership_fun,
         terminal_states,
         set_terminal_verification_pending_fun
       ) do
    {verification_issue_ids, deferred_issue_ids} =
      Enum.split(issue_ids, @idle_terminal_verification_batch_size)

    disappeared_issue_ids = MapSet.new(verification_issue_ids)

    case fetch_issue_states_fun.(verification_issue_ids) do
      {:ok, refreshed_issues} when is_list(refreshed_issues) ->
        returned_issue_ids =
          refreshed_issues
          |> Enum.flat_map(fn
            %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
            _issue -> []
          end)
          |> MapSet.new()

        failed_issue_ids =
          Enum.reduce(
            refreshed_issues,
            MapSet.difference(disappeared_issue_ids, returned_issue_ids),
            fn issue, failed_issue_ids ->
              issue
              |> record_refreshed_terminal_member(
                disappeared_issue_ids,
                observe_membership_fun,
                terminal_states,
                set_terminal_verification_pending_fun
              )
              |> retain_refreshed_terminal_verification(
                failed_issue_ids,
                issue,
                set_terminal_verification_pending_fun
              )
            end
          )

        MapSet.to_list(failed_issue_ids) ++ deferred_issue_ids

      _result ->
        verification_issue_ids ++ deferred_issue_ids
    end
  end

  defp record_refreshed_terminal_member(
         %Issue{id: _issue_id} = issue,
         disappeared_issue_ids,
         observe_membership_fun,
         terminal_states,
         set_terminal_verification_pending_fun
       ) do
    if terminal_disappearing_issue?(issue, disappeared_issue_ids, terminal_states) do
      record_and_clear_refreshed_terminal(
        issue,
        observe_membership_fun,
        set_terminal_verification_pending_fun
      )
    else
      :not_terminal
    end
  end

  defp record_refreshed_terminal_member(
         _issue,
         _disappeared_issue_ids,
         _observe_membership_fun,
         _terminal_states,
         _set_terminal_verification_pending_fun
       ),
       do: :not_terminal

  defp retain_refreshed_terminal_verification(
         result,
         failed_issue_ids,
         issue,
         _set_terminal_verification_pending_fun
       )
       when result in [:ok, :not_terminal] do
    MapSet.delete(failed_issue_ids, issue.id)
  end

  defp retain_refreshed_terminal_verification(
         {:error, _reason},
         failed_issue_ids,
         issue,
         set_terminal_verification_pending_fun
       ) do
    _ =
      safely_set_terminal_verification_pending(
        set_terminal_verification_pending_fun,
        issue.tracker_identity,
        true
      )

    MapSet.put(failed_issue_ids, issue.id)
  end

  defp terminal_disappearing_issue?(issue, disappeared_issue_ids, terminal_states) do
    MapSet.member?(disappeared_issue_ids, issue.id) and
      DispatchPolicy.terminal_issue_state?(issue.state, terminal_states)
  end

  defp record_and_clear_refreshed_terminal(
         issue,
         observe_membership_fun,
         set_terminal_verification_pending_fun
       ) do
    case MembershipLifecycle.record(
           issue,
           MembershipLifecycle.terminal_lifecycle(issue.state),
           observe_membership_fun
         ) do
      :ok ->
        clear_refreshed_terminal_verification(
          issue,
          set_terminal_verification_pending_fun
        )

      error ->
        error
    end
  end

  defp clear_refreshed_terminal_verification(issue, set_terminal_verification_pending_fun) do
    case safely_set_terminal_verification_pending(
           set_terminal_verification_pending_fun,
           issue.tracker_identity,
           false
         ) do
      :ok -> :ok
      :error -> {:error, :terminal_verification_marker_failed}
    end
  end

  defp retain_pending_terminal_verification([], _mark_reconciled_fun, _set_terminal_verification_pending_fun), do: :ok

  defp retain_pending_terminal_verification(
         pending_issue_ids,
         mark_reconciled_fun,
         _set_terminal_verification_pending_fun
       )
       when is_list(pending_issue_ids) do
    safely_mark_reconciled(mark_reconciled_fun, :unavailable)
  end

  defp safely_set_terminal_verification_pending(set_terminal_verification_pending_fun, identity, pending?) do
    case set_terminal_verification_pending_fun.(identity, pending?) do
      :ok -> :ok
      _ -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp safely_mark_reconciled(mark_reconciled_fun, status) do
    _ = mark_reconciled_fun.(status)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp emit_dependency_transition_events(%State{} = state, previous_issue, %Issue{} = issue) do
    if is_nil(previous_issue) do
      state
    else
      previous_blockers = blocker_map(previous_issue)
      current_blockers = blocker_map(issue)

      added_blocker_ids = Map.keys(current_blockers) -- Map.keys(previous_blockers)
      removed_blocker_ids = Map.keys(previous_blockers) -- Map.keys(current_blockers)
      shared_blocker_ids = Map.keys(current_blockers) -- added_blocker_ids

      state =
        Enum.reduce(added_blocker_ids, state, fn blocker_id, state_acc ->
          blocker = current_blockers[blocker_id]
          subscribe_and_maybe_enqueue_dependency(state_acc, issue, blocker)
        end)

      state =
        Enum.reduce(removed_blocker_ids, state, fn blocker_id, state_acc ->
          blocker = previous_blockers[blocker_id]
          # The resume stays outside the gating helper on purpose. #1821 made a
          # cleared dependency wake its blockee; putting that behind a failed
          # unsubscribe RPC would reintroduce exactly the stall it fixed. Only
          # the derived event is deferred to the next reconcile.
          state_acc
          |> unsubscribe_and_maybe_enqueue_dependency(issue, blocker)
          |> PushRouting.maybe_resume_blockee_on_cleared_dependency(issue, blocker, :removed)
        end)

      Enum.reduce(shared_blocker_ids, state, fn blocker_id, state_acc ->
        maybe_enqueue_blocker_terminality_event(
          state_acc,
          issue,
          previous_blockers[blocker_id],
          current_blockers[blocker_id]
        )
      end)
    end
  end

  defp emit_dependency_transition_events(%State{} = state, _previous_issue, _issue), do: state

  defp emit_task_state_transition_alert(%State{} = state, nil, %Issue{} = issue) do
    if DispatchPolicy.state_slug(issue.state) == "error" do
      emit_observed_error_transition_alert(state, issue)
    else
      resolve_observed_error_transition_alert(state, issue)
    end
  end

  defp emit_task_state_transition_alert(
         %State{} = state,
         %Issue{} = previous_issue,
         %Issue{} = issue
       ) do
    previous_state = DispatchPolicy.state_slug(previous_issue.state)
    current_state = DispatchPolicy.state_slug(issue.state)

    cond do
      is_nil(current_state) ->
        state

      previous_state == current_state ->
        reconcile_observed_error_alert(state, issue, current_state)

      current_state == "error" ->
        emit_observed_error_transition_alert(state, issue)

      previous_state == "error" ->
        resolve_observed_error_transition_alert(state, issue)

      true ->
        # Ticket B: label-flip alerts route through the new topic shape so
        # the alerts file can glob-match per state without one entry per state.
        Alerts.emit_system(
          "ticket.#{issue.identifier}.issue.label.added.agent.#{current_state}",
          issue: issue,
          worker_host: Orchestrator.running_worker_host(state, issue.id),
          reason: task_state_alert_reason(current_state),
          needs_attention: task_state_needs_attention?(current_state),
          severity: task_state_alert_severity(current_state)
        )

        clear_observed_error_alert(state, issue.id)
    end
  end

  defp emit_task_state_transition_alert(%State{} = state, _previous_issue, _issue), do: state

  defp reconcile_observed_error_alert(state, issue, "error"),
    do: emit_observed_error_transition_alert(state, issue)

  defp reconcile_observed_error_alert(state, issue, _state),
    do: resolve_observed_error_transition_alert(state, issue)

  defp emit_observed_error_transition_alert(%State{} = state, %Issue{} = issue) do
    cause = observed_error_alert_cause(state, issue)
    topic = observed_error_alert_topic(issue, cause)

    if MapSet.member?(state.observed_error_alerts, issue.id) or active_attention?(state, topic) do
      mark_observed_error_alert(state, issue.id, cause)
    else
      message = observed_error_alert_message(cause)

      case Alerts.emit_system(topic,
             issue: issue,
             worker_host: Orchestrator.running_worker_host(state, issue.id),
             reason: message,
             needs_attention: true,
             severity: "warning",
             central: true
           ) do
        :ok -> mark_observed_error_alert(state, issue.id, cause)
        {:error, _reason} -> state
      end
    end
  end

  defp resolve_observed_error_transition_alert(%State{} = state, %Issue{} = issue) do
    cause = observed_error_alert_cause(state, issue)
    topic = observed_error_alert_topic(issue, cause)

    active? =
      MapSet.member?(state.observed_error_alerts, issue.id) or
        active_attention?(state, topic)

    cond do
      cause == :lifetime_latch and lifetime_latch_status(state, issue.id) != :inactive ->
        mark_observed_error_alert(state, issue.id, cause)

      active? ->
        case Alerts.emit_system("#{topic}.resolved",
               issue: issue,
               worker_host: Orchestrator.running_worker_host(state, issue.id),
               reason: "Tracker moved the ticket out of agent:error; the observed error condition is resolved.",
               needs_attention: false,
               severity: "info",
               central: true
             ) do
          :ok -> clear_observed_error_alert(state, issue.id)
          {:error, _reason} -> state
        end

      true ->
        state
    end
  end

  defp observed_error_alert_cause(%State{} = state, %Issue{} = issue) do
    cond do
      lifetime_latch_active?(state, issue.id) -> :lifetime_latch
      cause = Map.get(state.observed_error_alert_causes, issue.id) -> cause
      cause = persisted_observed_error_alert_cause(state, issue) -> cause
      true -> :observed_tracker_error
    end
  end

  defp persisted_observed_error_alert_cause(%State{} = state, %Issue{} = issue) do
    Enum.find([:lifetime_latch, :retry_exhausted, :observed_tracker_error], fn cause ->
      active_attention?(state, observed_error_alert_topic(issue, cause))
    end)
  end

  defp active_attention?(state, topic), do: MapSet.member?(state.active_attention_topics, topic)

  defp lifetime_latch_active?(%State{} = state, issue_id) when is_binary(issue_id) do
    lifetime_latch_status(state, issue_id) == :active
  end

  defp lifetime_latch_active?(_state, _issue_id), do: false

  defp lifetime_latch_status(%State{} = state, issue_id) when is_binary(issue_id) do
    maximum = Config.agent_max_dispatches_per_ticket()
    budget = get_in(state.dispatch_recovery, [:codex_thrash_budget, issue_id]) || %{}

    # A trip recorded in the live recovery state remains authoritative until
    # the dispatch budget explicitly clears it. Configuration may be reloaded
    # between the trip and this tracker observation, so do not reinterpret an
    # already-recorded latch through the current cap.
    memory_latched? = budget[:tripped] == :lifetime

    if memory_latched?, do: :active, else: persisted_latch_status(maximum, issue_id)
  end

  defp lifetime_latch_status(_state, _issue_id), do: :inactive

  defp persisted_latch_status(maximum, issue_id) when maximum > 0 do
    case DispatchBudgetStore.lifetime(issue_id) do
      {:ok, lifetime} when lifetime >= maximum -> :active
      {:ok, _lifetime} -> :inactive
      {:error, _reason} -> :unknown
    end
  end

  defp persisted_latch_status(_maximum, _issue_id), do: :inactive

  defp observed_error_alert_message(:lifetime_latch),
    do: "Agent remains in error because its lifetime dispatch latch is still active; Executor action is required."

  defp observed_error_alert_message(_cause),
    do:
      "Tracker observed agent:error without a specialized local cause; the ticket needs Executor review. " <>
        "This condition will not clear on its own until the ticket is moved out of error."

  defp observed_error_alert_topic(%Issue{} = issue, cause) do
    "ticket.#{issue.identifier}.agent.attention.error-#{cause}"
  end

  defp mark_observed_error_alert(state, issue_id, cause) do
    %{
      state
      | observed_error_alerts: MapSet.put(state.observed_error_alerts, issue_id),
        observed_error_alert_causes: Map.put(state.observed_error_alert_causes, issue_id, cause)
    }
  end

  defp clear_observed_error_alert(state, issue_id) do
    %{
      state
      | observed_error_alerts: MapSet.delete(state.observed_error_alerts, issue_id),
        observed_error_alert_causes: Map.delete(state.observed_error_alert_causes, issue_id)
    }
  end

  defp emit_tracker_pause_transition_alert(%State{} = state, nil, %Issue{} = issue) do
    if Issue.paused?(issue) do
      emit_tracker_pause_alert(state, issue)
    else
      resolve_tracker_pause_alert(state, issue)
    end

    state
  end

  defp emit_tracker_pause_transition_alert(
         %State{} = state,
         %Issue{} = previous_issue,
         %Issue{} = issue
       ) do
    case {Issue.paused?(previous_issue), Issue.paused?(issue)} do
      {false, true} ->
        emit_tracker_pause_alert(state, issue)

      {true, false} ->
        Alerts.emit_system("ticket.#{issue.identifier}.agent.unpaused",
          issue: issue,
          worker_host: Orchestrator.running_worker_host(state, issue.id),
          reason: "Tracker removed agent:paused; tracker=agent:#{issue.state}. No operator action is needed.",
          needs_attention: false,
          severity: "info"
        )

        resolve_tracker_pause_alert(state, issue, true)

      _ ->
        :ok
    end

    state
  end

  defp emit_tracker_pause_transition_alert(%State{} = state, _previous_issue, _issue), do: state

  defp emit_tracker_pause_alert(%State{} = state, %Issue{} = issue) do
    topic = "ticket.#{issue.identifier}.agent.paused"

    unless active_attention?(state, topic) do
      Alerts.emit_system(topic,
        issue: issue,
        worker_host: Orchestrator.running_worker_host(state, issue.id),
        reason:
          "Tracker added agent:paused (tracker pause override); tracker=agent:#{issue.state}. " <>
            "This clears when the operator removes agent:paused.",
        needs_attention: true,
        severity: "warning",
        central: true
      )
    end
  end

  defp resolve_tracker_pause_alert(state, issue), do: resolve_tracker_pause_alert(state, issue, false)

  defp resolve_tracker_pause_alert(%State{} = state, %Issue{} = issue, force?) do
    topic = "ticket.#{issue.identifier}.agent.paused"

    if force? or active_attention?(state, topic) do
      Alerts.emit_system("#{topic}.resolved",
        issue: issue,
        worker_host: Orchestrator.running_worker_host(state, issue.id),
        reason: "Tracker removed agent:paused; the tracker pause override is resolved.",
        needs_attention: false,
        severity: "info",
        central: true
      )
    else
      :ok
    end
  end

  defp task_state_alert_reason("human-review"),
    do: "Agent marked the ticket ready for human review"

  defp task_state_alert_reason(_state), do: nil

  defp task_state_needs_attention?("human-review"), do: true
  defp task_state_needs_attention?(_state), do: false

  defp task_state_alert_severity("human-review"), do: "warning"
  defp task_state_alert_severity(_state), do: nil

  @spec blocker_map(term()) :: map()
  def blocker_map(%Issue{blocked_by: blockers}) when is_list(blockers) do
    Enum.reduce(blockers, %{}, fn
      %{id: blocker_id} = blocker, acc when is_binary(blocker_id) ->
        Map.put(acc, blocker_id, blocker)

      _blocker, acc ->
        acc
    end)
  end

  def blocker_map(_issue), do: %{}

  defp blocker_terminal?(%{state: state_name}) when is_binary(state_name) do
    DispatchPolicy.terminal_issue_state?(state_name, DispatchPolicy.terminal_state_set())
  end

  defp blocker_terminal?(_blocker), do: false

  defp maybe_enqueue_blocker_terminality_event(state, issue, previous_blocker, current_blocker) do
    cond do
      blocker_terminal?(previous_blocker) and !blocker_terminal?(current_blocker) ->
        enqueue_dependency_event(state, issue, current_blocker, :blocker_became_non_terminal)

      !blocker_terminal?(previous_blocker) and blocker_terminal?(current_blocker) ->
        state
        |> enqueue_dependency_event(issue, current_blocker, :blocker_became_terminal)
        |> PushRouting.maybe_resume_blockee_on_cleared_dependency(issue, current_blocker)

      true ->
        state
    end
  end

  defp unsubscribe_and_maybe_enqueue_dependency(state_acc, issue, blocker) do
    case AutoSubscriptions.auto_unsubscribe_for_dependency(issue, blocker) do
      :ok ->
        enqueue_dependency_event(state_acc, issue, blocker, :dependency_removed)

      {:error, reason} ->
        blocker_id = blocker["identifier"] || Map.get(blocker, :identifier)

        Logger.warning(
          "IssueSync: unsubscription failed for dependency_removed " <>
            "(#{issue.identifier} unblocked by #{blocker_id}): " <>
            "#{inspect(reason)}; event will emit on next reconcile"
        )

        state_acc
    end
  end

  defp subscribe_and_maybe_enqueue_dependency(state_acc, issue, blocker) do
    case AutoSubscriptions.auto_subscribe_for_dependency(issue, blocker) do
      :ok ->
        enqueue_dependency_event(state_acc, issue, blocker, :dependency_added)

      {:error, reason} ->
        blocker_id = blocker["identifier"] || Map.get(blocker, :identifier)

        Logger.warning(
          "IssueSync: subscription failed for dependency_added " <>
            "(#{issue.identifier} blocked by #{blocker_id}): " <>
            "#{inspect(reason)}; event will emit on next reconcile"
        )

        state_acc
    end
  end

  # Public because `PushRouting` enqueues a `:blocker_became_terminal` event
  # through it; keep it exported even though this module is its main caller.
  @doc false
  @spec enqueue_dependency_event(State.t(), Issue.t(), map(), atom()) :: State.t()
  def enqueue_dependency_event(%State{} = state, %Issue{} = issue, blocker, update_kind)
      when is_map(blocker) do
    body = blocker_event_body(issue, blocker, update_kind)

    {queue_store, item} =
      AgentQueue.coordination_event(issue.identifier, update_kind, body,
        source: :tracker,
        dedupe_key: dependency_event_dedupe_key(issue, blocker, update_kind),
        causal_refs: dependency_causal_refs(issue, blocker),
        subscription: dependency_subscription(issue, blocker)
      )
      |> then(&AgentQueueStore.enqueue(state.queue_store, &1))

    next_state = %{state | queue_store: queue_store}

    case State.find_running_by_identifier(state.running, issue.identifier) do
      nil ->
        next_state

      running_entry ->
        OperatorMessages.notify_running_queue_update(running_entry, item)
        next_state
    end
  end

  def enqueue_dependency_event(%State{} = state, _issue, _blocker, _update_kind), do: state

  defp blocker_event_body(issue, blocker, update_kind) do
    %{
      blocked_issue_id: issue.id,
      blocked_issue_identifier: issue.identifier,
      blocker_issue_id: blocker[:id],
      blocker_issue_identifier: blocker[:identifier],
      blocker_state: blocker[:state],
      update_kind: update_kind,
      summary: blocker_event_summary(issue, blocker, update_kind)
    }
  end

  defp blocker_event_summary(_issue, blocker, :dependency_added),
    do: "Issue is now blocked by #{blocker[:identifier] || blocker[:id]}"

  defp blocker_event_summary(_issue, blocker, :dependency_removed),
    do: "Dependency on #{blocker[:identifier] || blocker[:id]} was removed"

  defp blocker_event_summary(_issue, blocker, :blocker_became_terminal),
    do: "Blocker #{blocker[:identifier] || blocker[:id]} reached terminal state #{blocker[:state]}"

  defp blocker_event_summary(_issue, blocker, :blocker_became_non_terminal),
    do: "Blocker #{blocker[:identifier] || blocker[:id]} returned to non-terminal state #{blocker[:state]}"

  defp dependency_event_dedupe_key(issue, blocker, update_kind) do
    [
      Atom.to_string(update_kind),
      issue.id || issue.identifier,
      blocker[:id] || blocker[:identifier],
      blocker[:state]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp dependency_causal_refs(issue, blocker) do
    [issue.id, blocker[:id]]
    |> Enum.reject(&is_nil/1)
  end

  defp dependency_subscription(issue, blocker) do
    %{
      subscription_type: :blocked_by,
      source_issue_id: blocker[:id],
      target_issue_id: issue.id
    }
  end

  @spec sync_todo_capacity_alert(State.t(), list()) :: State.t()
  def sync_todo_capacity_alert(%State{} = state, issues) when is_list(issues) do
    todo_issues = routable_todo_issues(issues)

    over_capacity? = length(todo_issues) > Slots.max_concurrent_agent_limit(state)

    cond do
      over_capacity? and not state.todo_over_capacity_alert_active ->
        emit_todo_capacity_alert(state, todo_issues)
        %{state | todo_over_capacity_alert_active: true}

      not over_capacity? and state.todo_over_capacity_alert_active ->
        %{state | todo_over_capacity_alert_active: false}

      true ->
        state
    end
  end

  def sync_todo_capacity_alert(%State{} = state, _issues), do: state

  @doc false
  @spec sync_capacity_starvation_alert(State.t(), list(), integer()) :: State.t()
  def sync_capacity_starvation_alert(%State{} = state, issues, now_ms)
      when is_list(issues) and is_integer(now_ms) do
    constraint_entries = capacity_constraint_entries(state, issues)

    state
    |> capacity_starvation_context(issues, constraint_entries)
    |> sync_capacity_starvation_state(now_ms)
  end

  def sync_capacity_starvation_alert(%State{} = state, _issues, _now_ms), do: state

  @spec sync_capacity_starvation_alert(State.t(), list()) :: State.t()
  def sync_capacity_starvation_alert(%State{} = state, issues) when is_list(issues),
    do: sync_capacity_starvation_alert(state, issues, System.monotonic_time(:millisecond))

  def sync_capacity_starvation_alert(%State{} = state, _issues), do: state

  @doc false
  @spec sync_fleet_capacity_starved_alert(State.t(), list(), integer()) :: State.t()
  def sync_fleet_capacity_starved_alert(%State{} = state, issues, now_ms)
      when is_list(issues) and is_integer(now_ms) do
    context = fleet_capacity_context(state, issues)

    if fleet_capacity_starved?(context) do
      sync_fleet_capacity_starvation(state, context, now_ms)
    else
      clear_fleet_capacity_starvation(state)
    end
  end

  def sync_fleet_capacity_starved_alert(%State{} = state, _issues, _now_ms), do: state

  @spec sync_fleet_capacity_starved_alert(State.t(), list()) :: State.t()
  def sync_fleet_capacity_starved_alert(%State{} = state, issues) when is_list(issues),
    do: sync_fleet_capacity_starved_alert(state, issues, System.monotonic_time(:millisecond))

  def sync_fleet_capacity_starved_alert(%State{} = state, _issues), do: state

  @doc false
  @spec sync_dependency_circular_wait_alert(State.t(), list(), integer()) :: State.t()
  def sync_dependency_circular_wait_alert(%State{} = state, issues, now_ms)
      when is_list(issues) and is_integer(now_ms) do
    if circular_wait_detection_enabled?(state) do
      waits = dependency_circular_waits(state, issues)

      resolve_dependency_circular_waits(state.dependency_circular_wait, waits)

      next_waits =
        waits
        |> Map.values()
        |> Enum.sort_by(& &1.identifier)
        |> Enum.reduce(%{}, fn wait, next ->
          previous = Map.get(state.dependency_circular_wait, wait.id)
          entry = update_dependency_circular_wait(previous, wait, now_ms)
          Map.put(next, wait.id, entry)
        end)

      %{state | dependency_circular_wait: next_waits}
    else
      state
    end
  end

  def sync_dependency_circular_wait_alert(%State{} = state, _issues, _now_ms), do: state

  @spec sync_dependency_circular_wait_alert(State.t(), list()) :: State.t()
  def sync_dependency_circular_wait_alert(%State{} = state, issues) when is_list(issues),
    do: sync_dependency_circular_wait_alert(state, issues, System.monotonic_time(:millisecond))

  def sync_dependency_circular_wait_alert(%State{} = state, _issues), do: state

  defp fleet_capacity_context(state, issues) do
    sample = state.dispatch_capacity_sample
    constraint_entries = capacity_constraint_entries(state, issues)
    ready_issues = ready_dispatch_issues(state, issues)
    live_count = State.active_running_count(state.running)
    effective_cap = Slots.effective_concurrent_agent_limit(state)

    %{
      state: state,
      ready_count: length(ready_issues),
      live_count: live_count,
      occupied_slots: Slots.used_slots(state),
      effective_cap: effective_cap,
      configured_cap: Slots.max_concurrent_agent_limit(state),
      load: Map.get(sample, :load),
      target: Map.get(sample, :target),
      schedulers: Map.get(sample, :schedulers),
      constraints: Enum.map(constraint_entries, & &1.identity),
      binding_constraint: selected_binding_constraint(state, constraint_entries, ready_issues)
    }
  end

  defp dependency_circular_waits(state, issues) do
    waiters_by_blocker = dependency_waiters_by_blocker(state.running)

    Enum.reduce(issues, %{}, fn
      %Issue{id: id, identifier: identifier} = issue, waits when is_binary(id) and is_binary(identifier) ->
        waiting_count = Map.get(waiters_by_blocker, identifier, 0)

        if waiting_count > 0 and queued_undispatched?(issue, state) do
          Map.put(waits, id, %{id: id, identifier: identifier, waiting_count: waiting_count})
        else
          waits
        end

      _issue, waits ->
        waits
    end)
  end

  # DispatchPolicy only evaluates static ticket and slot eligibility. During a
  # global pause, prewarm hold, or host-pressure hold it can still describe a
  # queued ticket as dispatchable even though the dispatcher deliberately did
  # not attempt it. Those expected holds are not dependency cycles.
  defp circular_wait_detection_enabled?(%State{globally_paused: true}), do: false
  defp circular_wait_detection_enabled?(%State{capacity_hold: hold}) when not is_nil(hold), do: false
  defp circular_wait_detection_enabled?(%State{prewarm_hold_ticks: ticks}) when is_integer(ticks) and ticks > 0, do: false
  defp circular_wait_detection_enabled?(%State{}), do: true

  defp dependency_waiters_by_blocker(running) do
    Enum.reduce(running, %{}, fn
      {_issue_id, %{paused_reason: :blocker_dependency, blocker_pause: %{blocker_identifier: identifier}}}, waiters
      when is_binary(identifier) and identifier != "" ->
        Map.update(waiters, identifier, 1, &(&1 + 1))

      _running, waiters ->
        waiters
    end)
  end

  defp queued_undispatched?(%Issue{} = issue, state) do
    DispatchPolicy.dispatch_decision(issue, state) in [:dispatch, {:skip, :fleet_capacity}]
  end

  defp update_dependency_circular_wait(previous, wait, now_ms) do
    since_ms = if is_map(previous), do: previous.since_ms, else: now_ms
    alerted? = is_map(previous) and previous.alerted? == true
    entry = Map.merge(wait, %{since_ms: since_ms, alerted?: alerted?})

    if alerted? or now_ms - since_ms < @capacity_starvation_alert_after_ms do
      entry
    else
      emit_dependency_circular_wait(entry)
    end
  end

  defp emit_dependency_circular_wait(entry) do
    topic = dependency_circular_wait_topic(entry.identifier)
    message = "Circular wait: #{entry.identifier} is queued while #{entry.waiting_count} parked agent(s) wait on it."

    case Alerts.emit_system(topic,
           message: message,
           issue: entry.identifier,
           reason: message,
           needs_attention: true,
           severity: "warning"
         ) do
      :ok -> %{entry | alerted?: true}
      {:error, _reason} -> entry
    end
  end

  defp resolve_dependency_circular_waits(previous_waits, current_waits) do
    previous_waits
    |> Map.reject(fn {id, _entry} -> Map.has_key?(current_waits, id) end)
    |> Map.values()
    |> Enum.filter(&(&1.alerted? == true))
    |> Enum.each(fn entry ->
      message = "Circular wait cleared for #{entry.identifier}."

      Alerts.emit_system(dependency_circular_wait_topic(entry.identifier) <> ".resolved",
        message: message,
        issue: entry.identifier,
        reason: message,
        needs_attention: false,
        severity: "info"
      )
    end)
  end

  defp dependency_circular_wait_topic(identifier),
    do: "ticket.#{identifier}.agent.attention.dependency-circular-wait"

  # The fleet is starved only when ready work is queued AND dispatch is
  # genuinely held: a hard capacity gate is binding, or the fleet is at its
  # dispatch envelope (no free admission slots) while the envelope is not
  # mid-ramp, or the fleet is below a fully-ramped envelope that should already
  # have been filled. The below-target dispatch ramp — a fleet below or at a
  # widening envelope with agents still starting — is the intended behavior,
  # not starvation (#2447).
  defp fleet_capacity_starved?(context) do
    not context.state.globally_paused and context.ready_count > 0 and
      (hard_capacity_gate?(context) or fleet_at_capacity_bound?(context))
  end

  # A resource or load gate holding dispatch while ready work queues. These are
  # the genuine-starvation cases (acceptance #2): load, memory, FD, build,
  # run-queue, provider, budget, per-state, worker, or model-fallback limits.
  defp hard_capacity_gate?(context) do
    is_binary(context.binding_constraint) or context.constraints != []
  end

  # The fleet has no free admission slots within the current dispatch envelope
  # (the envelope is the binding constraint) and the envelope is not widening,
  # or the fleet is below a fully-ramped envelope that should have been filled.
  # A below-envelope fleet during a below-target ramp is the intended ramp.
  defp fleet_at_capacity_bound?(context) do
    cond do
      context.occupied_slots >= context.effective_cap -> not envelope_ramping?(context)
      context.effective_cap >= context.configured_cap -> true
      true -> false
    end
  end

  # The adaptive envelope widens while load stays at/below target and effective
  # capacity is still below the ceiling; that below-target state is the ramp.
  defp envelope_ramping?(%{effective_cap: effective, configured_cap: configured} = context)
       when is_integer(effective) and effective > 0 and is_integer(configured) and configured > 0 do
    effective < configured and load_below_or_at_target?(context)
  end

  defp envelope_ramping?(_context), do: false

  defp load_below_or_at_target?(%{load: load, target: target, schedulers: schedulers})
       when is_number(load) and is_number(target) and target > 0 and is_integer(schedulers) and schedulers > 0,
       do: load <= target * schedulers

  defp load_below_or_at_target?(_context), do: false

  defp sync_fleet_capacity_starvation(state, context, now_ms) do
    starvation = state.fleet_capacity_starvation

    if is_integer(starvation[:effective_cap]) and starvation[:effective_cap] != context.effective_cap do
      put_fleet_capacity_starvation(state, now_ms, starvation[:alert_active] || false, context.effective_cap)
    else
      since_ms = starvation[:since_ms] || now_ms

      if starvation[:alert_active] or now_ms - since_ms < fleet_capacity_starvation_alert_after_ms(state) do
        put_fleet_capacity_starvation(state, since_ms, starvation[:alert_active] || false, context.effective_cap)
      else
        emit_fleet_capacity_starvation(state, context, since_ms)
      end
    end
  end

  # Deliberately cadence-derived, and deliberately the *effective* cadence
  # rather than the configured one. Fleet starvation is only observable on a
  # poll tick, and starvation means no agent is running — which is exactly when
  # idle backoff widens the tick. A de-bounce shorter than one observation cycle
  # is no de-bounce at all: it alerts on the first observation. Reading
  # `poll_interval_ms` (the base) made that true the moment `idle_widen_factor`
  # went above 1.0. The cost is an alert that arrives one widened cycle after
  # starvation begins; the alternative is an alert that fires before the
  # dispatcher has had a chance to clear it.
  #
  # Routed through `PollCadence` rather than used raw so the de-bounce inherits
  # the same bound on a remote `X-Poll-Interval` as every other cadence-derived
  # threshold: a server that asks Aiur to poll rarely must not also be able to
  # silence its starvation alert.
  defp fleet_capacity_starvation_alert_after_ms(%State{effective_poll_interval_ms: effective_ms})
       when is_integer(effective_ms) and effective_ms > 0 do
    PollCadence.effective_interval_ms(effective_interval_ms: effective_ms)
  end

  defp fleet_capacity_starvation_alert_after_ms(%State{poll_interval_ms: poll_interval_ms})
       when is_integer(poll_interval_ms) and poll_interval_ms > 0,
       do: poll_interval_ms

  defp fleet_capacity_starvation_alert_after_ms(_state),
    do: Config.capacity_starvation_alert_after_seconds() * 1_000

  defp emit_fleet_capacity_starvation(state, context, since_ms) do
    case Alerts.emit_system("system.fleet.capacity.starved",
           reason: fleet_capacity_starvation_reason(context),
           needs_attention: true,
           severity: "warning"
         ) do
      :ok ->
        state
        |> Map.put(:fleet_capacity_starvation_resolution_emitted, false)
        |> put_fleet_capacity_starvation(since_ms, true, context.effective_cap)

      {:error, _reason} ->
        put_fleet_capacity_starvation(state, since_ms, false, context.effective_cap)
    end
  end

  defp fleet_capacity_starvation_reason(context) do
    "Ready tickets=#{context.ready_count}, live agents=#{context.live_count}, " <>
      "load=#{context.load}/#{context.target * context.schedulers}, effective cap=#{context.effective_cap}, " <>
      "configured cap=#{context.configured_cap}; binding constraint=#{fleet_capacity_constraint(context)}."
  end

  defp fleet_capacity_constraint(%{binding_constraint: constraint}) when is_binary(constraint), do: constraint

  defp fleet_capacity_constraint(%{occupied_slots: occupied, live_count: live}) when occupied > live,
    do: "paused agent reservations (occupied slots=#{occupied})"

  defp fleet_capacity_constraint(%{effective_cap: effective, configured_cap: configured, live_count: live})
       when effective <= live and effective < configured,
       do: "load envelope (effective cap=#{effective})"

  defp fleet_capacity_constraint(%{effective_cap: effective, configured_cap: configured, live_count: live})
       when effective <= live and effective == configured,
       do: "configured concurrency ceiling (cap=#{configured})"

  defp fleet_capacity_constraint(_context), do: "no binding constraint identified"

  defp selected_binding_constraint(%State{prewarm_blocked_alert_active: true}, entries, _ready_issues) do
    entries |> Enum.find(&(&1.identity == "build")) |> then(&(&1 && &1.detail))
  end

  defp selected_binding_constraint(%State{capacity_hold: %{signal: signal}}, entries, _ready_issues) do
    entries
    |> Enum.find(&(&1.identity == capacity_hold_identity(signal)))
    |> then(&(&1 && &1.detail))
  end

  defp selected_binding_constraint(state, entries, ready_issues) do
    case Enum.filter(entries, &String.starts_with?(&1.identity, "per-state:")) do
      [_ | _] = per_state_entries -> Enum.map_join(per_state_entries, "; ", & &1.detail)
      _ -> model_fallback_constraint(state, ready_issues) || worker_capacity_constraint(state, ready_issues)
    end
  end

  defp model_fallback_constraint(%State{model_fallback_waiting: waiting}, ready_issues) do
    waiting_count = Enum.count(ready_issues, &MapSet.member?(waiting, &1.id))

    if waiting_count > 0 do
      "dispatch authorization denials (all fallback backends usage-limited for #{waiting_count} ready ticket(s))"
    end
  end

  defp worker_capacity_constraint(state, ready_issues) do
    if Enum.any?(ready_issues, &(CodingAgent.backend_for(&1) |> CodingAgent.remote_worker?())) and
         not Slots.worker_slots_available?(state) do
      "worker-host capacity (all SSH worker slots are occupied)"
    end
  end

  defp capacity_hold_identity(:build), do: "build-queue"
  defp capacity_hold_identity(:envelope), do: "load-envelope"
  defp capacity_hold_identity(:file_descriptors), do: "fd"
  defp capacity_hold_identity(:run_queue), do: "run-queue"
  defp capacity_hold_identity(signal), do: to_string(signal)

  defp clear_fleet_capacity_starvation(%State{fleet_capacity_starvation_resolution_emitted: true} = state),
    do: put_fleet_capacity_starvation(state, nil, false, nil)

  defp clear_fleet_capacity_starvation(%State{} = state) do
    starvation = state.fleet_capacity_starvation

    active? = starvation[:alert_active] or AlertFeed.active_system_attention?("system.fleet.capacity.starved")

    if active? do
      case Alerts.emit_system("system.fleet.capacity.starved.resolved",
             reason: "Fleet capacity is no longer starved.",
             needs_attention: false,
             severity: "info"
           ) do
        :ok ->
          state
          |> Map.put(:fleet_capacity_starvation_resolution_emitted, true)
          |> put_fleet_capacity_starvation(nil, false, nil)

        {:error, _reason} ->
          state
      end
    else
      state
      |> Map.put(:fleet_capacity_starvation_resolution_emitted, true)
      |> put_fleet_capacity_starvation(nil, false, nil)
    end
  end

  defp put_fleet_capacity_starvation(state, since_ms, alert_active, effective_cap) do
    %{state | fleet_capacity_starvation: %{since_ms: since_ms, alert_active: alert_active, effective_cap: effective_cap}}
  end

  defp capacity_starvation_context(state, issues, constraint_entries) do
    %{
      state: state,
      configured: Slots.max_concurrent_agent_limit(state),
      effective: Slots.effective_concurrent_agent_limit(state),
      ready_count: state |> ready_dispatch_issues(issues) |> length(),
      constraints: Enum.map(constraint_entries, & &1.detail),
      signature: capacity_constraint_signature(constraint_entries)
    }
  end

  defp sync_capacity_starvation_state(%{ready_count: 0} = context, _now_ms),
    do: clear_capacity_starvation(context.state)

  defp sync_capacity_starvation_state(%{constraints: []} = context, _now_ms),
    do: clear_capacity_starvation(context.state)

  defp sync_capacity_starvation_state(context, now_ms) do
    starvation = Map.get(context.state, :capacity_starvation, %{})
    since_by_identity = capacity_starvation_ages(starvation, context.signature, now_ms)
    alerted_identities = active_alerted_identities(starvation, context.signature)
    due_identities = due_capacity_identities(since_by_identity, alerted_identities, now_ms)

    if due_identities == [] do
      put_capacity_starvation(context.state, since_by_identity, alerted_identities, context.signature)
    else
      emit_capacity_starvation_alert(context, since_by_identity, alerted_identities, due_identities)
    end
  end

  defp capacity_starvation_ages(starvation, identities, now_ms) do
    previous_ages = previous_capacity_starvation_ages(starvation, identities, now_ms)
    Map.new(identities, &{&1, Map.get(previous_ages, &1, now_ms)})
  end

  defp previous_capacity_starvation_ages(%{since_ms: ages}, _identities, _now_ms) when is_map(ages), do: ages

  defp previous_capacity_starvation_ages(%{since_ms: since_ms, signature: signature}, identities, _now_ms)
       when is_integer(since_ms) do
    Map.new(signature || identities, &{&1, since_ms})
  end

  defp previous_capacity_starvation_ages(_starvation, _identities, _now_ms), do: %{}

  defp active_alerted_identities(starvation, identities) do
    alerted =
      case Map.get(starvation, :alerted) do
        alerted when is_list(alerted) -> alerted
        _ -> legacy_alerted_identities(starvation, identities)
      end

    MapSet.intersection(MapSet.new(alerted), MapSet.new(identities))
  end

  defp legacy_alerted_identities(starvation, identities) do
    if Map.get(starvation, :alert_active) == true, do: starvation[:signature] || identities, else: []
  end

  defp due_capacity_identities(since_by_identity, alerted_identities, now_ms) do
    since_by_identity
    |> Enum.filter(fn {identity, since_ms} ->
      now_ms - since_ms >= capacity_starvation_dwell_ms() and not MapSet.member?(alerted_identities, identity)
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # The capacity-starvation dwell is data (#2447): `agent.capacity_starvation_
  # alert_after_seconds`, so the below-target ramp (which clears itself within
  # the bound) is filtered without hard-coding the threshold in this branch.
  defp capacity_starvation_dwell_ms, do: Config.capacity_starvation_alert_after_seconds() * 1_000

  defp emit_capacity_starvation_alert(context, since_by_identity, alerted_identities, due_identities) do
    next_alerted_identities = MapSet.union(alerted_identities, MapSet.new(due_identities))

    case Alerts.emit_system("system.dispatch.capacity_starved",
           reason: capacity_starvation_reason(context),
           needs_attention: true,
           severity: "warning"
         ) do
      :ok ->
        context.state
        |> put_capacity_starvation(since_by_identity, next_alerted_identities, context.signature)
        |> Map.put(:capacity_starvation_resolution_emitted, false)

      {:error, _reason} ->
        put_capacity_starvation(context.state, since_by_identity, alerted_identities, context.signature)
    end
  end

  defp capacity_starvation_reason(context) do
    "Ready tickets=#{context.ready_count}, live agents=#{State.active_running_count(context.state.running)}, " <>
      "effective cap=#{context.effective}, configured cap=#{context.configured}; " <>
      "dispatch constraints=#{Enum.join(context.constraints, "; ")}."
  end

  defp clear_capacity_starvation(%State{capacity_starvation_resolution_emitted: true} = state),
    do: put_cleared_capacity_starvation(state)

  defp clear_capacity_starvation(%State{} = state) do
    active? =
      Map.get(state.capacity_starvation, :alert_active, false) or
        AlertFeed.active_system_attention?("system.dispatch.capacity_starved")

    if active? do
      case Alerts.emit_system("system.dispatch.capacity_starved.resolved",
             reason: "Ready-work dispatch capacity recovered; fleet dispatch may resume.",
             needs_attention: false,
             severity: "info"
           ) do
        :ok -> put_cleared_capacity_starvation(%{state | capacity_starvation_resolution_emitted: true})
        {:error, _reason} -> state
      end
    else
      put_cleared_capacity_starvation(%{state | capacity_starvation_resolution_emitted: true})
    end
  end

  defp put_cleared_capacity_starvation(state),
    do: %{state | capacity_starvation: %{since_ms: %{}, alert_active: false, signature: [], alerted: []}}

  defp put_capacity_starvation(state, since_by_identity, alerted_identities, signature) do
    %{
      state
      | capacity_starvation: %{
          since_ms: since_by_identity,
          alert_active: MapSet.size(alerted_identities) > 0,
          signature: signature,
          alerted: alerted_identities |> MapSet.to_list() |> Enum.sort()
        }
    }
  end

  defp routable_todo_issues(issues) when is_list(issues) do
    issues
    |> Enum.filter(fn
      %Issue{} = issue ->
        DispatchPolicy.normalize_issue_state(issue.state) == "todo" and
          not Issue.paused?(issue) and
          not Issue.parked?(issue) and
          DispatchPolicy.issue_routable_to_worker?(issue) and
          !DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, DispatchPolicy.terminal_state_set())

      _ ->
        false
    end)
    |> DispatchPolicy.sort_issues_for_dispatch()
  end

  defp ready_dispatch_issues(%State{} = state, issues) do
    active_states = DispatchPolicy.active_state_set()
    terminal_states = DispatchPolicy.terminal_state_set()

    issues
    |> Enum.filter(fn issue ->
      # A ticket waiting on an open operator Command is not capacity-blocked:
      # no amount of fleet capacity can start it. Counting it as ready makes a
      # decision-blocked fleet look capacity-starved (#2447). Dispatch already
      # skips these via `dispatch_state_decision`; keep the alert's "ready"
      # set aligned with what dispatch can actually admit.
      DispatchPolicy.candidate_issue?(issue, active_states, terminal_states) and
        !DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
        !DispatchPolicy.blocked_on_decision?(issue, state.blocked_ticket_ids)
    end)
    |> Enum.reject(fn issue ->
      Map.has_key?(state.running, issue.id) or MapSet.member?(state.claimed, issue.id) or
        Map.has_key?(state.retry_attempts, issue.id)
    end)
  end

  defp capacity_constraint_entries(%State{} = state, issues) do
    state.dispatch_capacity_constraints
    |> Enum.flat_map(&dispatch_capacity_constraint_entry/1)
    |> Kernel.++(per_state_capacity_constraint_entries(state, issues))
    |> Kernel.++(budget_capacity_constraint_entries(state, issues))
    |> Enum.uniq_by(& &1.identity)
    |> Enum.sort_by(& &1.detail)
  end

  defp capacity_constraint_signature(constraint_entries) do
    constraint_entries
    |> Enum.map(& &1.identity)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dispatch_capacity_constraint_entry(%{kind: kind} = constraint) do
    case render_capacity_constraint(constraint) do
      detail when is_binary(detail) -> [%{identity: dispatch_constraint_identity(kind), detail: detail}]
      nil -> []
    end
  end

  defp dispatch_capacity_constraint_entry(_constraint), do: []

  defp dispatch_constraint_identity(:build), do: "build"
  defp dispatch_constraint_identity(:build_queue), do: "build-queue"
  defp dispatch_constraint_identity(:fd), do: "fd"
  defp dispatch_constraint_identity(:load), do: "load"
  defp dispatch_constraint_identity(:load_envelope), do: "load-envelope"
  defp dispatch_constraint_identity(:memory), do: "memory"
  defp dispatch_constraint_identity(:provider), do: "provider"
  defp dispatch_constraint_identity(:run_queue), do: "run-queue"
  defp dispatch_constraint_identity(kind), do: "dispatch:#{kind}"

  defp render_capacity_constraint(%{kind: :build, detail: detail}), do: "prewarm build (#{detail})"

  defp render_capacity_constraint(%{kind: :build_queue, detail: detail}),
    do: "build-queue gate (#{detail})"

  defp render_capacity_constraint(%{kind: :fd, detail: detail}), do: "FD gate (#{detail})"
  defp render_capacity_constraint(%{kind: :load, detail: detail}), do: "load gate (#{detail})"

  defp render_capacity_constraint(%{kind: :load_envelope, detail: detail}),
    do: "load-envelope limit (#{detail})"

  defp render_capacity_constraint(%{kind: :memory, detail: detail}), do: "memory gate (#{detail})"

  defp render_capacity_constraint(%{kind: :provider, detail: detail}),
    do: "provider gate (#{detail})"

  defp render_capacity_constraint(%{kind: :run_queue, detail: detail}),
    do: "run-queue gate (#{detail})"

  defp render_capacity_constraint(_constraint), do: nil

  defp per_state_capacity_constraint_entries(%State{} = state, issues) do
    configured_limits = Config.settings!().agent.max_concurrent_agents_by_state || %{}

    ready_dispatch_issues(state, issues)
    |> Enum.map(&DispatchPolicy.normalize_issue_state(&1.state))
    |> Enum.uniq()
    |> Enum.flat_map(&per_state_capacity_constraint_entry(state, configured_limits, &1))
  end

  defp per_state_capacity_constraint_entry(state, configured_limits, issue_state) do
    with {:ok, limit} <- Map.fetch(configured_limits, issue_state),
         used <- DispatchPolicy.running_issue_count_for_state(state.running, issue_state),
         true <- used >= limit do
      [%{identity: "per-state:#{issue_state}", detail: "per-state limit (#{issue_state}=#{used}/#{limit})"}]
    else
      _ -> []
    end
  end

  defp budget_capacity_constraint_entries(%State{} = state, issues) do
    budget = get_in(state.dispatch_recovery, [:codex_thrash_budget]) || %{}

    ready_dispatch_issues(state, issues)
    |> Enum.flat_map(&budget_capacity_constraint_entry(&1.id, Map.get(budget, &1.id, %{})))
  end

  defp budget_capacity_constraint_entry(issue_id, %{tripped: :lifetime} = entry) do
    [%{identity: "budget:lifetime:#{issue_id}", detail: "budget latch (lifetime=#{Map.get(entry, :lifetime, 0)})"}]
  end

  defp budget_capacity_constraint_entry(issue_id, %{tripped: :window} = entry) do
    case budget_window_remaining_ms(entry, System.monotonic_time(:millisecond)) do
      remaining_ms when remaining_ms > 0 ->
        [%{identity: "budget:window:#{issue_id}", detail: "budget circuit (window, clears #{format_remaining_duration(remaining_ms)})"}]

      _ ->
        []
    end
  end

  defp budget_capacity_constraint_entry(_issue_id, _entry), do: []

  defp budget_window_remaining_ms(entry, now_ms) do
    window_ms = Config.codex_thrash_window_seconds() * 1_000
    max(0, Map.get(entry, :window_start_ms, now_ms) + window_ms - now_ms)
  end

  defp format_remaining_duration(milliseconds) when milliseconds < 60_000, do: "in <1m"
  defp format_remaining_duration(milliseconds), do: "in ~#{div(milliseconds + 59_999, 60_000)}m"

  defp emit_todo_capacity_alert(%State{} = state, todo_issues) when is_list(todo_issues) do
    case List.first(todo_issues) do
      %Issue{} = issue ->
        Alerts.emit_system("system.dispatch.todo_capacity_exceeded",
          issue: issue,
          worker_host: Orchestrator.running_worker_host(state, issue.id),
          reason: "Todo issue count exceeds the current dispatch capacity.",
          needs_attention: true,
          severity: "warning"
        )

      _ ->
        Alerts.emit_system("system.dispatch.todo_capacity_exceeded",
          reason: "Todo issue count exceeds the current dispatch capacity.",
          needs_attention: true,
          severity: "warning"
        )
    end
  end
end
