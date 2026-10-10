defmodule Aiur.Orchestrator.Dispatcher.Candidates do
  @moduledoc """
  Candidate fetch, per-issue dispatch validation and the blocked-by dependency gate.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.Commands
  alias Aiur.Config
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher.Launch
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerHealth
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.Tracker

  # Refreshes the open-blocking-Command ticket set in State from the local store.
  # The dispatch gate is fail-closed: `:unavailable` (the decision store could
  # not be read) holds every new dispatch, because an open blocking Command is
  # indistinguishable from an empty store when the store cannot be read. The
  # Reconciler reads the same value but fails OPEN (it never stops healthy
  # running agents on a store outage).
  @spec refresh_blocked_ticket_ids(State.t(), GenServer.server()) :: State.t()
  def refresh_blocked_ticket_ids(%State{} = state, store \\ Commands.default_store()) do
    case Commands.blocked_ticket_ids(store) do
      {:ok, %MapSet{} = ids} -> %{state | blocked_ticket_ids: ids}
      {:error, :store_unavailable} -> %{state | blocked_ticket_ids: :unavailable}
    end
  end

  @doc false
  @spec fetch_candidate_issues(State.t(), keyword()) ::
          {:ok, [Issue.t()], State.t()} | {:error, term(), State.t()} | {:paused, State.t()}
  def fetch_candidate_issues(state, opts \\ [])

  def fetch_candidate_issues(%State{globally_paused: true} = state, _opts), do: {:paused, state}

  def fetch_candidate_issues(%State{} = state, opts) when is_list(opts) do
    # Dispatch labels are mutable authority. Keep this cache separate from the
    # lifecycle label caches and revalidate its all-open representation on
    # every poll.
    fetch_fun = Keyword.get(opts, :fetch_fun, &default_candidate_fetch/1)
    cache = candidate_list_cache(state)

    apply_candidate_result(state, fetch_fun.(cache))
  end

  @doc false
  @spec apply_candidate_result(State.t(), {:ok, [Issue.t()], map()} | {:error, term()}) ::
          {:paused, State.t()} | {:ok, [Issue.t()], State.t()} | {:error, term(), State.t()}
  def apply_candidate_result(%State{globally_paused: true} = state, _result), do: {:paused, state}

  def apply_candidate_result(state, result) do
    case result do
      {:ok, issues, updated_cache} ->
        state = state |> put_candidate_list_cache(updated_cache) |> note_candidate_fetch_success()
        {:ok, issues, state}

      {:error, reason} ->
        {:error, reason, mark_candidate_snapshot_unavailable(state, reason)}
    end
  end

  defp note_candidate_fetch_success(%State{} = state) do
    state = %{state | candidate_snapshot_fresh?: true}

    if Config.tracker_kind() == "github" do
      TrackerHealth.note_github_connectivity_success(state, :candidates)
    else
      state
    end
  end

  defp mark_candidate_snapshot_unavailable(%State{} = state, reason) do
    state = %{state | candidate_snapshot_fresh?: false, snapshot_ready?: true}

    if Config.tracker_kind() == "github" do
      TrackerHealth.note_github_connectivity_failure(state, :candidates, reason)
    else
      state
    end
  end

  @doc false
  @spec default_candidate_fetch(map()) :: {:ok, [Issue.t()], map()} | {:error, term()}
  def default_candidate_fetch(cache) do
    if Config.tracker_kind() == "github" do
      GitHubTracker.fetch_candidate_issues_conditional(cache)
    else
      with {:ok, issues} <- Tracker.fetch_candidate_issues(), do: {:ok, issues, cache}
    end
  end

  @doc false
  @spec candidate_list_cache(State.t()) :: map()
  def candidate_list_cache(%State{ci_lifecycle: ci_lifecycle}) do
    ci_lifecycle |> Map.get(:poll_cache, %{}) |> Map.get(:candidate_list_cache, %{})
  end

  defp put_candidate_list_cache(%State{} = state, cache) do
    update_in(state.ci_lifecycle.poll_cache, &Map.put(&1 || %{}, :candidate_list_cache, cache))
  end

  # `:unauthorized` is in this list because it is the one decline an operator
  # cannot otherwise see. A dispatch-authorization read that is *deferred* (a
  # local GitHub budget hold, a rate limit, a transport fault on the timeline
  # fetch) leaves `dispatch_authorized?: false` with a `Logger.warning` and
  # nothing else, and the catch-all clause below then actively cleared any
  # prior decline. A ticket relabelled `agent:rework` while the core budget is
  # held therefore sat out poll after poll with free slots, no alert, and no
  # row on the status board — the operator saw only silence. Recording the
  # decline makes the hold legible; it does not change whether the ticket
  # dispatches.
  @doc false
  @spec maybe_emit_dispatch_decline(State.t(), Issue.t(), term()) :: State.t()
  def maybe_emit_dispatch_decline(%State{} = state, %Issue{} = issue, reason)
      when reason in [
             :state_capacity,
             :worker_capacity,
             :claimed_without_runtime,
             :blocked_on_decision,
             :unauthorized
           ] do
    if Slots.available_slots(state) > 0 do
      record_dispatch_decline(
        state,
        issue,
        reason,
        "Ticket #{issue.identifier} was not selected despite free fleet slots: #{reason}",
        reason == :claimed_without_runtime
      )
    else
      state
    end
  end

  def maybe_emit_dispatch_decline(%State{} = state, %Issue{} = issue, _reason),
    do: clear_dispatch_decline(state, issue)

  @doc false
  @spec start_dispatch_validation(State.t(), term(), term(), term(), keyword()) :: State.t()
  def start_dispatch_validation(state, issue, attempt, preferred_worker_host, opts) do
    expected = dispatch_input(state, issue.id)
    blocked_ids = state.blocked_ticket_ids

    TrackerTasks.run(
      state,
      {:dispatch, issue.id},
      fn -> fetch_dispatch_validation(blocked_ids, issue, opts) end,
      fn current, result ->
        next = apply_current_dispatch_validation(current, expected, issue, attempt, preferred_worker_host, opts, result)
        Keyword.get(opts, :dispatch_result_fun, &Function.identity/1).(next)
      end
    )
  end

  defp fetch_dispatch_validation(blocked_ids, issue, opts) do
    case held_by_dependency_before_refresh(blocked_ids, issue, opts) do
      {:held, hydrated, _terminal_states} -> {:held, hydrated}
      :continue -> refresh_dispatch_validation(issue, opts)
    end
  end

  defp refresh_dispatch_validation(issue, opts) do
    fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    hydrator = Keyword.get(opts, :blocked_by_hydrator, &default_blocked_by_hydrator/1)

    case Launch.revalidate_issue_for_dispatch(issue, fetcher, DispatchPolicy.terminal_state_set(), opts) do
      {:ok, refreshed} -> {:validated, refreshed, hydrator.(refreshed)}
      other -> other
    end
  end

  defp apply_current_dispatch_validation(current, expected, issue, attempt, host, opts, result) do
    cond do
      dispatch_input(current, issue.id) != expected -> current
      current.globally_paused -> emit_dispatch_attempt_decline(current, issue, :globally_paused, false)
      true -> apply_dispatch_validation(current, issue, attempt, host, opts, result)
    end
  end

  defp apply_dispatch_validation(state, _issue, attempt, host, opts, {:validated, refreshed, hydration}) do
    policy_state = %{state | claimed: MapSet.delete(state.claimed, refreshed.id), auto_resume: Map.delete(state.auto_resume, refreshed.id)}

    case DispatchPolicy.dispatch_decision(refreshed, policy_state) do
      :dispatch -> state |> clear_dispatch_decline(refreshed) |> dispatch_with_dependency_gate(refreshed, attempt, host, Keyword.put(opts, :blocked_by_hydrator, fn _ -> hydration end))
      {:skip, reason} -> maybe_emit_dispatch_decline(state, refreshed, reason)
    end
  end

  defp apply_dispatch_validation(state, _issue, _attempt, _host, _opts, {:held, hydrated}) do
    Logger.info("Skipping dispatch before refresh; #{State.issue_context(hydrated)} " <> DispatchPolicy.describe_dependency_hold(hydrated, DispatchPolicy.terminal_state_set()))
    emit_dispatch_attempt_decline(state, hydrated, :dependency, false)
  end

  defp apply_dispatch_validation(state, issue, _attempt, _host, _opts, {:skip, :missing}),
    do: emit_dispatch_attempt_decline(state, issue, :missing_after_revalidation, false)

  defp apply_dispatch_validation(state, _issue, _attempt, _host, _opts, {:skip, %Issue{} = refreshed}) do
    reason =
      case DispatchPolicy.dispatch_decision(refreshed, state) do
        {:skip, reason} -> {:stale_after_revalidation, reason}
        :dispatch -> :stale_after_revalidation
      end

    emit_dispatch_attempt_decline(state, refreshed, reason, false)
  end

  defp apply_dispatch_validation(state, issue, _attempt, _host, _opts, result) do
    Logger.warning("Asynchronous dispatch validation declined: #{State.issue_context(issue)} result=#{inspect(result)}")
    emit_dispatch_attempt_decline(state, issue, :tracker_revalidation_failed, true)
  end

  defp dispatch_input(state, id) do
    entry = Map.get(state.running, id)

    {if(is_map(entry), do: Map.take(entry, [:pid, :ref, :session_id, :telemetry_attempt_id, :control, :lifecycle_fence]), else: entry), MapSet.member?(state.claimed, id),
     Map.get(state.auto_resume, id), Map.get(state.retry_attempts, id)}
  end

  # A todo ticket held by an open dependency cannot dispatch whatever its
  # refreshed state says, so the dependency gate runs first and a held ticket
  # spends no `issue_by_id` refresh and no `dispatch_authorization` read. Before
  # #2714 every held dependent paid both on every pass, which was a third of a
  # daemon's core spend on its own.
  #
  # Only a definite hold short-circuits. A failed or odd hydration, an issue
  # with no dependency hold, and an issue also held on a blocking Command
  # (whose decline reason takes precedence) all take the ordinary path, which
  # refreshes the issue and runs every gate again, fail-closed as before. The
  # gate needs the candidate to be `todo`, and the candidate's state is the
  # latest tracker poll's.
  defp held_by_dependency_before_refresh(blocked_ids, %Issue{} = issue, opts) do
    hydrator = Keyword.get(opts, :blocked_by_hydrator, &default_blocked_by_hydrator/1)

    with false <- DispatchPolicy.blocked_on_decision?(issue, blocked_ids),
         {:ok, %Issue{} = hydrated} <- hydrator.(issue),
         terminal_states = DispatchPolicy.terminal_state_set(),
         true <- DispatchPolicy.todo_issue_blocked_by_non_terminal?(hydrated, terminal_states) do
      {:held, hydrated, terminal_states}
    else
      _not_held -> :continue
    end
  end

  defp held_by_dependency_before_refresh(_state, _issue, _opts), do: :continue

  # GitHub-native `blocked_by` is hydrated only here — at the point an issue is
  # actually being dispatched — so the cost is bounded by dispatch attempts, not
  # by tracker size (#1631, against the #1388 read budget).
  #
  # The dependency decision is deliberately FAIL-CLOSED:
  #   * a known non-terminal blocker holds the issue (`:dependency` skip, info);
  #   * a failed or incomplete dependency read means blockers are *unknown*, and
  #     dispatching on unknown blockers would reintroduce exactly the "dispatches
  #     work GitHub knows is blocked" defect this gate exists to prevent, so the
  #     issue is held with an attention decline (`:dependency_hydration_failed`).
  # A `/dependencies` outage therefore holds dispatch rather than risking blocked
  # work; the tracker-wide quota gate already holds the fleet during GitHub-side
  # rate limiting, so fail-closed does not add a new outage class.
  @doc false
  @spec dispatch_with_dependency_gate(State.t(), Issue.t(), term(), term(), keyword()) :: State.t()
  def dispatch_with_dependency_gate(
        %State{} = state,
        %Issue{} = refreshed_issue,
        attempt,
        preferred_worker_host,
        opts
      )
      when is_list(opts) do
    hydrator = Keyword.get(opts, :blocked_by_hydrator, &default_blocked_by_hydrator/1)

    case hydrator.(refreshed_issue) do
      {:ok, %Issue{} = hydrated} ->
        # Dispatch-time mirror of the per-cycle gate in `choose_issues`. The
        # main dispatch path already refused the ticket, but resume/wake paths
        # (`CommentWake`, `AutoResume`, pause resume) call `dispatch_issue`
        # directly and must not spawn a fresh agent while the ticket's blocking
        # Command is still open — that is exactly the #1637 cold-start defect.
        # Fail-closed like the dependency gate: an unreadable decision store
        # holds dispatch.
        if DispatchPolicy.blocked_on_decision?(hydrated, state.blocked_ticket_ids) do
          Logger.info(
            "Skipping dispatch; issue has an open blocking Command: " <>
              "#{State.issue_context(hydrated)}"
          )

          emit_dispatch_attempt_decline(state, hydrated, :blocked_on_decision, false)
        else
          dispatch_issue_with_dependency_check(state, hydrated, attempt, preferred_worker_host, opts)
        end

      {:error, reason} ->
        Logger.warning(
          "Skipping dispatch; blocked-by hydration failed for #{State.issue_context(refreshed_issue)}: " <>
            "#{inspect(reason)} (fail-closed: unknown blockers hold dispatch)"
        )

        emit_dispatch_attempt_decline(state, refreshed_issue, :dependency_hydration_failed, true)

      # A hydrator that returns an unexpected shape must never crash the
      # orchestrator; treat it as unknown blockers and hold dispatch.
      other ->
        Logger.warning(
          "Skipping dispatch; blocked-by hydration returned an unexpected result for " <>
            "#{State.issue_context(refreshed_issue)}: #{inspect(other)} (fail-closed)"
        )

        emit_dispatch_attempt_decline(state, refreshed_issue, :dependency_hydration_failed, true)
    end
  end

  defp dispatch_issue_with_dependency_check(state, hydrated, attempt, preferred_worker_host, opts) do
    terminal_states = DispatchPolicy.terminal_state_set()

    if DispatchPolicy.todo_issue_blocked_by_non_terminal?(hydrated, terminal_states) do
      Logger.info(
        "Skipping dispatch; #{State.issue_context(hydrated)} " <>
          DispatchPolicy.describe_dependency_hold(hydrated, terminal_states)
      )

      # Record the decline instead of only logging it. A ticket held here sits in
      # "awaiting-dispatch" for as long as its blocker is open, and with nothing
      # in `dispatch_declines` the status board and alert feed showed no reason at
      # all — the operator saw an idle fleet and a stuck ticket with no link
      # between them (#2545). Non-attention (info): a blocked ticket is normal
      # dependency ordering, not a fault.
      emit_dispatch_attempt_decline(state, hydrated, :dependency, false)
    else
      Launch.do_dispatch_issue(state, hydrated, attempt, preferred_worker_host, opts)
    end
  end

  # The GitHub tracker populates `blocked_by` from the native Issue Dependencies
  # API only when the issue is being considered for a blocked_by decision
  # (dispatch, or dependency-pause recheck in `PushRouting`). Other trackers
  # (Linear, memory) already carry hydrated blockers from their poll response,
  # so hydration is a passthrough.
  @doc false
  @spec default_blocked_by_hydrator(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def default_blocked_by_hydrator(%Issue{} = issue) do
    if github_tracker_kind?() do
      GitHubTracker.hydrate_blocked_by(issue)
    else
      {:ok, issue}
    end
  end

  # `Config.settings/0`, not `Config.tracker_kind/0` (which raises when no
  # workflow file is present): this hydrator is also invoked from the
  # dependency-pause recheck path that unit tests exercise without a workflow
  # file, so "no config" must mean "not a GitHub tracker" (passthrough), never
  # a crash.
  @doc false
  @spec github_tracker_kind?() :: boolean()
  def github_tracker_kind? do
    case Config.settings() do
      {:ok, %{tracker: %{kind: kind}}} -> kind == "github"
      _ -> false
    end
  end

  defp emit_dispatch_attempt_decline(%State{} = state, %Issue{} = issue, reason, attention?) do
    record_dispatch_decline(
      state,
      issue,
      reason,
      "Ticket #{issue.identifier} was selected but dispatch stopped: #{inspect(reason)}",
      attention?
    )
  end

  defp record_dispatch_decline(%State{} = state, %Issue{} = issue, reason, alert_reason, attention?) do
    if Map.get(state.dispatch_declines, issue.id) == reason do
      state
    else
      state = maybe_resolve_dispatch_decline(state, issue)

      Alerts.emit_custom(
        dispatch_decline_topic(issue, attention?),
        "Dispatch declined for #{issue.identifier}: #{inspect(reason)}.",
        issue: issue.identifier,
        reason: alert_reason,
        needs_attention: attention?,
        severity: if(attention?, do: "warning", else: "info"),
        event_source: :system
      )

      %{state | dispatch_declines: Map.put(state.dispatch_declines, issue.id, reason)}
    end
  end

  defp clear_dispatch_decline(%State{} = state, %Issue{} = issue) do
    state = maybe_resolve_dispatch_decline(state, issue)
    %{state | dispatch_declines: Map.delete(state.dispatch_declines, issue.id)}
  end

  defp maybe_resolve_dispatch_decline(%State{} = state, %Issue{} = issue) do
    case Map.get(state.dispatch_declines, issue.id) do
      reason when reason in [:claimed_without_runtime, :tracker_revalidation_failed, :dependency_hydration_failed] ->
        Alerts.emit_custom(
          dispatch_decline_topic(issue, true) <> ".resolved",
          "Dispatch decline cleared for #{issue.identifier}.",
          issue: issue.identifier,
          reason: "Ticket #{issue.identifier} is no longer blocked by #{reason}.",
          needs_attention: false,
          severity: "info",
          event_source: :system
        )

      _other ->
        :ok
    end

    state
  end

  defp dispatch_decline_topic(%Issue{id: issue_id}, true),
    do: "ticket.#{issue_id}.agent.attention.dispatch-declined"

  defp dispatch_decline_topic(_issue, false), do: "dispatch.candidate_declined"
end
