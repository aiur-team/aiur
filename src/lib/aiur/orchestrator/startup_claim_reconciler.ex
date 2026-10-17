defmodule Aiur.Orchestrator.StartupClaimReconciler do
  @moduledoc """
  Releases orphaned tracker claims after a grace period on every candidate poll.

  Live registry entries, workspace leases, scheduled retries and operator holds
  protect a claim. Failed writes retain the existing bounded retry policy.
  """

  require Logger

  alias Aiur.{Alerts, Issue}
  alias Aiur.Orchestrator.{CiLifecycle, DispatchPolicy, Lifecycle, Reconciler, State, TrackerTasks}
  alias Aiur.Orchestrator.StartupClaimReconciler.{BootMarker, Observation, Release}

  @max_release_attempts 3
  @ancestry_backoff_ms 30_000
  @ancestry_backoff_cap_ms 600_000
  # Some ancestry failures never clear (a diff of 300+ files or over 100 commits), so alert once after this long.
  @ancestry_persistent_ms 3_600_000

  @spec reconcile(State.t(), [Issue.t()], keyword()) :: {State.t(), [Issue.t()]}
  def reconcile(state, issues, opts \\ [])

  def reconcile(%State{startup_claim_reconciliation_complete?: true} = state, issues, opts)
      when is_list(issues) do
    do_run_pass(state, issues, opts)
  end

  def reconcile(%State{} = state, issues, opts) when is_list(issues) and is_list(opts) do
    boot_id = Aiur.Boot.run_id()
    read_marker_fun = Keyword.get(opts, :read_boot_marker_fun, &default_read_marker/0)

    case read_marker_fun.() do
      {:ok, ^boot_id} when map_size(state.startup_claim_reconciliation_failures) > 0 or map_size(state.orphaned_claim_since) > 0 ->
        # Same daemon boot, same Orchestrator generation mid-pass: a previous
        # poll recorded release failures, so continue the pass and retry them
        # against the current registry (which now carries this generation's
        # live runtimes, so a continuing pass cannot release a live claim).
        run_pass(state, issues, boot_id, opts)

      {:ok, ^boot_id} ->
        # Restart cleanup stops untracked runners; workspace leases still
        # protect remote or reaping sessions. A prior pass cannot disable recovery.
        do_run_pass(state, issues, opts)

      {:ok, _other_boot_or_no_marker} ->
        # No claim for the current boot (fresh daemon boot, or an earlier boot
        # whose pass never finished): run the pass once and claim this boot.
        run_pass(state, issues, boot_id, opts)

      {:error, reason} ->
        Logger.error(
          "Startup claim reconciliation boot marker unreadable; failing closed (claims retained): " <>
            "#{inspect(reason)}"
        )

        {state, issues}
    end
    |> then(fn {current, issues} -> {current, reject_pending_releases(current, issues)} end)
  end

  defp run_pass(%State{} = state, issues, boot_id, opts) do
    mark_marker_fun = Keyword.get(opts, :mark_boot_marker_fun, &default_mark_marker/1)

    case mark_marker_fun.(boot_id) do
      :ok ->
        do_run_pass(state, issues, opts)

      {:error, reason} ->
        # The boot could not be claimed, so a later Orchestrator generation in
        # this boot could not know the pass already started. Failing closed is
        # the safe direction: never release on evidence that cannot survive a
        # restart.
        Logger.error(
          "Startup claim reconciliation could not claim this boot; failing closed (claims retained): " <>
            "#{inspect(reason)}"
        )

        {state, issues}
    end
  end

  defp do_run_pass(%State{} = state, issues, opts) do
    state = Observation.observe(state, issues, opts)
    live_identifiers = live_runtime_identifiers(state.running)

    {issues, {state, unsettled?}} =
      Enum.map_reduce(issues, {state, false}, fn issue, {state_acc, unsettled?} ->
        case reconcile_issue(state_acc, issue, live_identifiers, opts) do
          {:ok, state_acc, issue} -> {issue, {state_acc, unsettled?}}
          {:retry, state_acc, issue} -> {issue, {state_acc, true}}
          {:latched, state_acc, issue} -> {issue, {state_acc, unsettled?}}
        end
      end)

    # The pass completes once every candidate is settled — protected by a live
    # runtime, successfully released, or latched after exhausting its retries.
    # Permanently failing writes stay latched; unavailable PR evidence retries.
    {%{state | startup_claim_reconciliation_complete?: not unsettled?}, Enum.reject(issues, &is_nil/1)}
  end

  defp reconcile_issue(%State{} = state, %Issue{identifier: identifier} = issue, live_identifiers, opts)
       when is_binary(identifier) do
    cond do
      approved_armed_orphan?(state, issue, identifier, live_identifiers, opts) ->
        release_orphaned_claim(state, issue, Keyword.put(opts, :forced_target, "ci-wait"))

      not recoverable_claim?(state, issue, identifier) ->
        {:ok, resolve_release_failure(state, issue, opts), issue}

      not Observation.expired?(state, issue, opts) ->
        {:retry, state, issue}

      MapSet.member?(live_identifiers, identifier) ->
        {:ok, resolve_release_failure(state, issue, opts), issue}

      TrackerTasks.issue_pending?(state, issue.id) ->
        {:retry, state, nil}

      backing_off?(state, issue, opts) ->
        {:retry, state, issue}

      retry_exhausted?(state, issue) ->
        # Already latched this boot: leave the claim in place and never
        # re-attempt it, and do not block pass completion.
        {:latched, state, issue}

      true ->
        release_orphaned_claim(state, issue, opts)
    end
  end

  defp reconcile_issue(state, issue, _live_identifiers, _opts), do: {:ok, state, issue}

  defp recoverable_claim?(state, issue, identifier) do
    DispatchPolicy.state_slug(issue.state) == "in-progress" and
      not CiLifecycle.approved_and_armed?(state, issue) and Map.has_key?(state.orphaned_claim_since, identifier)
  end

  defp approved_armed_orphan?(state, issue, identifier, live_identifiers, opts) do
    DispatchPolicy.state_slug(issue.state) == "in-progress" and CiLifecycle.approved_and_armed?(state, issue) and
      Map.has_key?(state.orphaned_claim_since, identifier) and Observation.expired?(state, issue, opts) and
      not MapSet.member?(live_identifiers, identifier) and not TrackerTasks.issue_pending?(state, issue.id)
  end

  # Positive current-generation liveness. A live Task pid protects its claim; a
  # parked/staged entry (`pid: nil` — a rate-limit-fallback redispatch or a
  # deactivated row) is still owned by this generation while a replacement is
  # being admitted, so it protects the claim too. Only an entry whose Task pid
  # is verifiably dead counts as absence.
  defp live_runtime_identifiers(running) do
    Enum.reduce(running, MapSet.new(), fn
      {_issue_id, %{identifier: identifier} = entry}, identifiers when is_binary(identifier) ->
        if current_generation_claim?(entry), do: MapSet.put(identifiers, identifier), else: identifiers

      _entry, identifiers ->
        identifiers
    end)
  end

  defp current_generation_claim?(%{pid: nil}), do: true
  defp current_generation_claim?(%{pid: pid}), do: State.alive?(pid)
  defp current_generation_claim?(_entry), do: false

  defp release_orphaned_claim(%State{} = state, %Issue{} = issue, opts) do
    if TrackerTasks.owner?(state) do
      input = Reconciler.issue_input(state, issue.id) |> Tuple.delete_at(1)
      update = fn -> Release.run(issue, Keyword.put(opts, :state, state)) end

      current =
        TrackerTasks.run(state, {:startup_release, issue.id}, update, fn arg1, arg2 ->
          apply_orphan_release(arg1, arg2, {input, issue, opts})
        end)

      {:retry, current, nil}
    else
      release_orphaned_claim_sync(state, issue, opts)
    end
  end

  defp reject_pending_releases(state, issues), do: Enum.reject(issues, &TrackerTasks.running?(state, {:startup_release, &1.id}))

  defp release_orphaned_claim_sync(%State{} = state, %Issue{} = issue, opts) do
    case Release.run(issue, Keyword.put(opts, :state, state)) do
      {:ok, target} ->
        Logger.warning("Released orphaned startup claim to #{target}; no live runtime owns it #{State.issue_context(issue)}")
        emit_released_alert(issue, target, opts)
        state = resolve_release_failure(state, issue, opts)
        state = %{state | claimed: MapSet.delete(state.claimed, issue.id), orphaned_claim_since: Map.delete(state.orphaned_claim_since, issue.identifier)}
        {:ok, state, %{issue | state: target, state_labels: [target]}}

      {:defer, reason} ->
        entry = Map.get(state.startup_claim_reconciliation_failures, issue.identifier, %{})
        attempts = Map.get(entry, :attempts, 0)
        emit_release_failed(state, issue, reason, attempts, opts, true)
        entry = entry |> deferred_entry(reason, attempts, opts) |> alert_persistent_ancestry(issue, opts)
        failures = Map.put(state.startup_claim_reconciliation_failures, issue.identifier, entry)
        {:retry, %{state | startup_claim_reconciliation_failures: failures}, issue}

      {:error, reason} ->
        handle_release_failure(state, issue, reason, opts)
    end
  end

  defp handle_release_failure(%State{} = state, %Issue{} = issue, reason, opts) do
    entry = Map.get(state.startup_claim_reconciliation_failures, issue.identifier, %{attempts: 0})
    attempts = Map.get(entry, :attempts, 0) + 1
    failures = Map.put(state.startup_claim_reconciliation_failures, issue.identifier, %{reason: reason, attempts: attempts})

    if attempts >= @max_release_attempts do
      Logger.error(
        "Startup claim release for #{issue.identifier} exhausted #{attempts} attempts; leaving the orphaned claim in place " <>
          "#{State.issue_context(issue)}"
      )

      emit_release_failed(state, issue, reason, attempts, opts)
      {:latched, %{state | startup_claim_reconciliation_failures: failures}, issue}
    else
      emit_release_failed(state, issue, reason, attempts, opts)
      {:retry, %{state | startup_claim_reconciliation_failures: failures}, issue}
    end
  end

  defp emit_release_failed(%State{} = state, %Issue{} = issue, reason, attempts, opts, deferred? \\ false) do
    Logger.error(
      "Failed to release orphaned startup claim: #{inspect(reason)}; " <>
        cond do
          deferred? -> "deferred to a later candidate poll without using an attempt "
          attempts >= @max_release_attempts -> "attempts exhausted; Executor intervention required "
          true -> "retry #{attempts}/#{@max_release_attempts} on a later candidate poll "
        end <>
        "#{State.issue_context(issue)}"
    )

    if attempts >= @max_release_attempts or not Map.has_key?(state.startup_claim_reconciliation_failures, issue.identifier) do
      emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

      emit_alert_fun.(
        failure_topic(issue),
        issue: issue,
        message:
          if(attempts >= @max_release_attempts,
            do: "Startup claim release for ticket #{issue.identifier} exhausted #{attempts} attempts; Executor intervention required.",
            else: "Startup reconciliation could not release ticket #{issue.identifier}; its orphaned in-progress claim remains."
          ),
        reason:
          "Ticket #{issue.identifier} has no live runtime, but its guarded update from in-progress to its recovery state failed " <>
            "(#{inspect(reason)}); " <> retry_outlook(reason, attempts, deferred?),
        needs_attention: true,
        severity: "warning",
        central: true,
        durable: true
      )
    end

    :ok
  end

  defp retry_outlook(:review_base_ancestry_unavailable, _attempts, true),
    do: "it will be retried with backoff (up to every #{div(@ancestry_backoff_cap_ms, 60_000)} min) without using up release attempts."

  defp retry_outlook(_reason, _attempts, true), do: "it will be retried on a later candidate poll without using up release attempts."
  defp retry_outlook(_reason, attempts, false) when attempts >= @max_release_attempts, do: "no further release attempts will run within this boot."
  defp retry_outlook(_reason, _attempts, false), do: "it will be retried up to #{@max_release_attempts} times within this boot."

  defp emit_released_alert(%Issue{} = issue, target, opts) do
    emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

    emit_alert_fun.(
      "ticket.#{issue.identifier}.agent.attention.startup_orphan_claim_released",
      issue: issue,
      message: "Startup reconciliation released ticket #{issue.identifier} from in-progress to #{target}.",
      reason:
        "Ticket #{issue.identifier} carried an in-progress claim but no live runtime in the current orchestrator " <>
          "registry owned it, so the claim was released by a guarded update.",
      needs_attention: false,
      severity: "warning",
      central: true,
      durable: true
    )
  end

  defp resolve_release_failure(%State{} = state, %Issue{} = issue, opts) do
    case Map.pop(state.startup_claim_reconciliation_failures, issue.identifier) do
      {nil, _failures} ->
        state

      {_entry, failures} ->
        emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

        emit_alert_fun.(
          failure_topic(issue) <> ".resolved",
          issue: issue,
          message: "Startup claim reconciliation recovered for ticket #{issue.identifier}.",
          reason: "A fresh tracker snapshot no longer reports an orphaned in-progress claim for ticket #{issue.identifier}.",
          needs_attention: false,
          severity: "info",
          central: true
        )

        %{state | startup_claim_reconciliation_failures: failures}
    end
  end

  # Ancestry reads retry with exponential backoff rather than on every candidate poll.
  defp deferred_entry(entry, :review_base_ancestry_unavailable = reason, attempts, opts) do
    defers = Map.get(entry, :defers, 0)
    delay = min(@ancestry_backoff_ms * Integer.pow(2, defers), @ancestry_backoff_cap_ms)
    now = now_ms(opts)
    Map.merge(entry, %{reason: reason, attempts: attempts, defers: defers + 1, retry_at: now + delay, since: Map.get(entry, :since, now)})
  end

  defp deferred_entry(_entry, reason, attempts, _opts), do: %{reason: reason, attempts: attempts}

  defp alert_persistent_ancestry(%{since: since} = entry, issue, opts) when not is_map_key(entry, :persistent_alerted) do
    if now_ms(opts) - since >= @ancestry_persistent_ms do
      emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

      emit_alert_fun.(
        failure_topic(issue),
        issue: issue,
        message: "Startup reconciliation has not released ticket #{issue.identifier} for over an hour: its review-base ancestry stays unavailable.",
        reason:
          "Ticket #{issue.identifier} has no live runtime, but the review-base ancestry check for its PR has failed for over " <>
            "#{div(@ancestry_persistent_ms, 60_000)} min. This usually does not clear on its own: the PR diff has 300 or more files " <>
            "or over 100 commits since its merge base. Relabel the ticket by hand; backoff retries continue without another alert.",
        needs_attention: true,
        severity: "warning",
        central: true,
        durable: true
      )

      Map.put(entry, :persistent_alerted, true)
    else
      entry
    end
  end

  defp alert_persistent_ancestry(entry, _issue, _opts), do: entry

  defp backing_off?(%State{} = state, %Issue{identifier: identifier}, opts) do
    case Map.get(state.startup_claim_reconciliation_failures, identifier) do
      %{retry_at: retry_at} -> now_ms(opts) < retry_at
      _other -> false
    end
  end

  defp now_ms(opts), do: Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

  defp retry_exhausted?(%State{} = state, %Issue{identifier: identifier}) do
    case Map.get(state.startup_claim_reconciliation_failures, identifier) do
      %{attempts: attempts} when is_integer(attempts) -> attempts >= @max_release_attempts
      _other -> false
    end
  end

  defp failure_topic(issue), do: "ticket.#{issue.identifier}.agent.attention.startup_claim_reconciliation_failed"

  # In the test environment every reconcile is a fresh boot so tests never leak
  # a boot claim across cases in the same VM; the gating logic itself is
  # exercised through injected marker functions.
  defp default_read_marker do
    if Application.get_env(:aiur, :env) == :test do
      {:ok, nil}
    else
      {:ok, BootMarker.claimed_boot_id()}
    end
  end

  defp default_mark_marker(boot_id) do
    if Application.get_env(:aiur, :env) == :test do
      :ok
    else
      BootMarker.claim(boot_id)
    end
  end

  defp apply_orphan_release(current, result, {input, issue, opts}) do
    latest = Map.get(current.last_polled_issues, issue.id, issue)

    if Reconciler.issue_input(current, issue.id) |> Tuple.delete_at(1) == input and latest.state == issue.state and
         not MapSet.member?(live_runtime_identifiers(current.running), issue.identifier) do
      {status, current, refreshed} =
        release_orphaned_claim_sync(
          current,
          latest,
          Keyword.put(opts, :release_fun, fn _issue, _opts -> result end)
        )

      current =
        if match?({:ok, _}, result) do
          %{current | last_polled_issues: Map.put(current.last_polled_issues, issue.id, refreshed)}
        else
          current
        end

      current =
        if status == :retry do
          %{current | startup_claim_reconciliation_complete?: false}
        else
          current
        end

      Lifecycle.wake_tick(current)
    else
      Lifecycle.wake_tick(current)
    end
  end
end
