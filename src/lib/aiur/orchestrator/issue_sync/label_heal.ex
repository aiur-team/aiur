defmodule Aiur.Orchestrator.IssueSync.LabelHeal do
  @moduledoc """
  Repairs contradictory tracker state labels through guarded writes.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.IssueSync.LabelWrites
  alias Aiur.Orchestrator.IssueSync.MissingLabels
  alias Aiur.Orchestrator.IssueSync.TransitionAlerts
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks

  # A contradictory-label pair must persist this long (about one poll cycle)
  # before the single fleet alert fires, so a pair the heal repairs on the same
  # observation never alarms.
  @contradictory_label_alert_after_ms 60_000
  # States a provenance resolution may promote over a stale daemon claim: real,
  # non-terminal dispositions only. `done` is excluded so a provenance win can
  # never close a ticket (#2437), `todo` is handled ahead of provenance, and an
  # unknown or mistyped label is never promoted.
  @provenance_promotable_states ~w(rework in-progress human-review error ci-wait)
  @doc """
  Heals polled issues that observe more than one `agent:*` state label.

  A ticket carrying both `agent:todo` and `agent:rework` is a broken lifecycle
  state: the dispatch guard used to refuse it, silently dropping the ticket
  from every poll with no error and no alert (#2075). This resolves the pair
  deterministically (`todo` wins — a ticket that is also `todo` has no work for a
  `rework` verdict to mean anything about), writes the winner through the tracker
  so GitHub stops carrying both labels, and logs the resolution.

  The winner is provenance-aware first and statically ordered second (#2805).
  When one of the two labels is the daemon's own prior claim — the state on its
  `running` entry, or the previous poll's single-label observation — the other
  label is the one that arrived since, so it is the real disposition and wins.
  Without that evidence `DispatchPolicy.resolve_state_labels/1` decides, and a
  provenance win never promotes the terminal `done` (#2437) or overrides `todo`. Transient write failures keep
  the resolved issue in the returned list so the ticket is still dispatchable
  this cycle; the next poll retries the heal.

  Returns `{state, healed_issues}` so the caller dispatches against the healed
  view and stores the healed copies in `last_polled_issues`.
  """
  @spec reconcile_contradictory_state_labels(State.t(), list()) :: {State.t(), list()}
  def reconcile_contradictory_state_labels(%State{} = state, issues) when is_list(issues) do
    reconcile_contradictory_state_labels(state, issues, LabelWrites.guarded_update_fun(issues))
  end

  @doc false
  @spec reconcile_contradictory_state_labels(State.t(), list(), (String.t(), String.t() -> :ok | {:error, term()})) ::
          {State.t(), list()}
  def reconcile_contradictory_state_labels(%State{} = state, issues, update_state_fun)
      when is_list(issues) and is_function(update_state_fun, 2) do
    state = %{state | active_attention_topics: TransitionAlerts.active_attention_topics()}
    previous_tickets = state.contradictory_state_label_tickets
    now_ms = System.monotonic_time(:millisecond)

    {healed_issues, state} =
      Enum.reduce(issues, {[], state}, fn issue, {acc, state_acc} ->
        state_acc = MissingLabels.resolve_missing_state_label_alert(issue, state_acc)

        case issue do
          %Issue{state_labels: [_, _ | _] = state_labels} = issue ->
            {healed_issue, state_acc} =
              heal_contradictory_state(issue, winner_for(state_labels, issue, state_acc), state_acc, update_state_fun)

            {retain_healed_issue(acc, healed_issue), state_acc}

          # `state_labels == []` is the GitHub normalizer's zero-label signal
          # (state is nil alongside it); `state_labels == nil` with no state is
          # the not-normalized equivalent. An issue that carries a real state
          # without a populated labels list (e.g. non-GitHub tracker fixtures)
          # is not a stranded zero-label ticket and is left untouched, and a
          # closed issue needs no state label at all (#2420).
          %Issue{state_labels: state_labels, state: state} = issue
          when (state_labels == [] or (state_labels == nil and is_nil(state))) and state != "Closed" ->
            {healed_issue, state_acc} = MissingLabels.heal_or_leave_missing_state_label(issue, state_acc, update_state_fun)
            {retain_healed_issue(acc, healed_issue), state_acc}

          _issue ->
            {[issue | acc], state_acc}
        end
      end)

    tickets = contradictory_state_label_tickets(issues, previous_tickets, now_ms)
    state = sync_contradictory_state_label_alert(state, tickets, now_ms)

    {state, Enum.reverse(healed_issues)}
  end

  def reconcile_contradictory_state_labels(%State{} = state, _issues, _update_state_fun), do: {state, []}

  # Resolving a contradictory pair by the static precedence list alone is
  # time- and provenance-blind, and that loses the one transition the daemon
  # and an agent can race on: the CI-pass handoff (#2805). The daemon swaps
  # `ci-wait` -> `in-progress` itself, the agent then adds `agent:human-review`
  # for the finished PR, and the static order ranks `in-progress` above
  # `human-review` — so the heal deleted the agent's fresh, deliberate handoff
  # and kept the daemon's own stale claim, leaving a ticket that was waiting on
  # a human marked as actively in progress (and re-woken by the turn loop,
  # because `in-progress` is an active state and `human-review` is not).
  #
  # The daemon does not need label timestamps to tell the two apart: it already
  # knows which of the two labels is its own prior claim, from its `running`
  # entry or the previous poll's single-label observation. Whatever label stands
  # *next to* that known-older claim is the one that arrived since, so it is the
  # real disposition and wins. This is evidence-gated, not shape-gated: with no
  # such evidence the static precedence still decides, so every pre-#2805
  # resolution is unchanged.
  defp winner_for(state_labels, %Issue{} = issue, %State{} = state) do
    normalized = normalized_state_labels(state_labels)
    claim = prior_daemon_state_claim(state, issue)

    case fresh_label_beside_claim(normalized, claim) do
      nil ->
        DispatchPolicy.resolve_state_labels(state_labels)

      fresh ->
        Logger.warning(
          "Contradictory state labels resolved by provenance for #{State.issue_context(issue)} " <>
            "labels=#{inspect(state_labels)} prior_claim=#{inspect(claim)} -> #{fresh}"
        )

        fresh
    end
  end

  # The single label that arrived since the daemon's own prior claim, or `nil`
  # when provenance cannot decide. `todo` keeps its special case ahead of
  # provenance — it means "no work exists yet", so it stays the honest fallback
  # rather than promoting a disposition about work that never happened — and the
  # promoted label must be a non-terminal disposition: healing to the terminal
  # `done` routes the tracker write into the close path and would discard
  # outstanding work (#2437), and an unknown or mistyped label must never win.
  defp fresh_label_beside_claim(normalized, claim) do
    with false <- "todo" in normalized,
         true <- is_binary(claim) and claim in normalized,
         [fresh] <- normalized -- [claim],
         true <- fresh in @provenance_promotable_states do
      fresh
    else
      _ -> nil
    end
  end

  # A label the daemon itself is known to have observed or written before this
  # poll: the state on its own `running` entry (refreshed by every daemon-side
  # transition, including the CI-pass handoff) first, then the previous poll's
  # observation when that carried exactly one state label.
  defp prior_daemon_state_claim(%State{} = state, %Issue{id: issue_id}) do
    running_state_claim(state, issue_id) || last_polled_state_claim(state, issue_id)
  end

  defp prior_daemon_state_claim(_state, _issue), do: nil

  defp running_state_claim(%State{running: running}, issue_id) when is_map(running) do
    case Map.get(running, issue_id) do
      %{issue: %Issue{state: state_name}} when is_binary(state_name) ->
        DispatchPolicy.normalize_state_label(state_name)

      _ ->
        nil
    end
  end

  defp last_polled_state_claim(%State{last_polled_issues: polled}, issue_id) when is_map(polled) do
    case Map.get(polled, issue_id) do
      %Issue{state_labels: [single]} ->
        DispatchPolicy.normalize_state_label(single)

      %Issue{state_labels: labels, state: state_name} when labels in [nil, []] and is_binary(state_name) ->
        DispatchPolicy.normalize_state_label(state_name)

      _ ->
        nil
    end
  end

  defp normalized_state_labels(state_labels) when is_list(state_labels) do
    state_labels
    |> Enum.map(&DispatchPolicy.normalize_state_label/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalized_state_labels(_state_labels), do: []

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
    if TrackerTasks.owner?(state) do
      LabelWrites.schedule_label_heal(state, issue, winner, update_state_fun, fn issue, current, update ->
        heal_contradictory_state_sync(issue, winner, current, update)
      end)
    else
      heal_contradictory_state_sync(issue, winner, state, update_state_fun)
    end
  end

  defp retain_healed_issue(acc, nil), do: acc
  defp retain_healed_issue(acc, issue), do: [issue | acc]

  defp heal_contradictory_state_sync(%Issue{} = issue, winner, state, update_state_fun) do
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
end
