defmodule Aiur.Orchestrator.StartupClaimReconciler do
  @moduledoc """
  Releases tracker claims whose runtime did not survive a daemon restart.

  The pass is gated by a boot marker (`Aiur.Boot.run_id/0` recorded in
  `BootMarker`): it runs from scratch only on a genuinely fresh daemon boot,
  and never re-runs from scratch on an Orchestrator-only restart where the
  agent tasks survived. Re-running from scratch after an Orchestrator crash
  would see an empty runtime registry, read every in-progress ticket as dead,
  release the claims of still-running agents, and re-dispatch the same ticket
  to two live agents on one branch.

  Within a boot a failing release is retried on later polls up to a per-ticket
  cap and then latched, so one durable tracker error (label permission, an
  archived ticket, a 422) can never turn the startup pass into a lifetime
  reaper that runs against all in-progress tickets forever.
  """

  require Logger

  alias Aiur.{Alerts, Config, Issue, Tracker}
  alias Aiur.Orchestrator.{DispatchPolicy, State}
  alias Aiur.Orchestrator.StartupClaimReconciler.BootMarker

  @max_release_attempts 3

  @spec reconcile(State.t(), [Issue.t()], keyword()) :: {State.t(), [Issue.t()]}
  def reconcile(state, issues, opts \\ [])

  def reconcile(%State{startup_claim_reconciliation_complete?: true} = state, issues, _opts)
      when is_list(issues) do
    {state, issues}
  end

  def reconcile(%State{} = state, issues, opts) when is_list(issues) and is_list(opts) do
    boot_id = Aiur.Boot.run_id()
    read_marker_fun = Keyword.get(opts, :read_boot_marker_fun, &default_read_marker/0)

    case read_marker_fun.() do
      {:ok, ^boot_id} when map_size(state.startup_claim_reconciliation_failures) > 0 ->
        # Same daemon boot, same Orchestrator generation mid-pass: a previous
        # poll recorded release failures, so continue the pass and retry them
        # against the current registry (which now carries this generation's
        # live runtimes, so a continuing pass cannot release a live claim).
        run_pass(state, issues, boot_id, opts)

      {:ok, ^boot_id} ->
        # This daemon boot already claimed its pass — either it completed, or
        # a prior Orchestrator generation was mid-flight when it restarted and
        # its surviving agents still own their claims. Re-running from scratch
        # here would read the empty registry as "everyone is dead" and release
        # live claims, forking the work. Skip and remember in memory.
        {%{state | startup_claim_reconciliation_complete?: true}, issues}

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
    # A permanently failing release must not keep the whole pass re-running.
    {%{state | startup_claim_reconciliation_complete?: not unsettled?}, issues}
  end

  defp reconcile_issue(%State{} = state, %Issue{identifier: identifier} = issue, live_identifiers, opts)
       when is_binary(identifier) do
    cond do
      DispatchPolicy.state_slug(issue.state) != "in-progress" ->
        {:ok, resolve_release_failure(state, issue, opts), issue}

      MapSet.member?(live_identifiers, identifier) ->
        {:ok, resolve_release_failure(state, issue, opts), issue}

      retry_exhausted?(state, issue) ->
        # Already latched this boot: leave the claim in place and never
        # re-attempt it, and do not block pass completion.
        {:latched, state, issue}

      true ->
        release_orphaned_claim(state, issue, opts)
    end
  end

  defp reconcile_issue(state, issue, _live_identifiers, _opts), do: {:ok, state, issue}

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
    todo_state = lifecycle_state_name(opts, "todo", "todo")

    update_issue_state_fun =
      Keyword.get(opts, :update_issue_state_fun, fn identifier, state_name, expected_state ->
        Tracker.update_issue_state(identifier, state_name, expected_state: expected_state)
      end)

    case update_issue_state_fun.(issue.identifier, todo_state, issue.state) do
      :ok ->
        Logger.warning(
          "Released orphaned startup claim to todo; no live runtime owns it " <>
            "#{State.issue_context(issue)}"
        )

        emit_released_alert(issue, opts)
        state = resolve_release_failure(state, issue, opts)
        {:ok, state, %{issue | state: todo_state}}

      {:error, reason} ->
        handle_release_failure(state, issue, reason, opts)

      unexpected ->
        handle_release_failure(state, issue, {:unexpected_result, unexpected}, opts)
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

      {:latched, %{state | startup_claim_reconciliation_failures: failures}, issue}
    else
      emit_release_failed(state, issue, reason, attempts, opts)
      {:retry, %{state | startup_claim_reconciliation_failures: failures}, issue}
    end
  end

  defp emit_release_failed(%State{} = state, %Issue{} = issue, reason, attempts, opts) do
    Logger.error(
      "Failed to release orphaned startup claim: #{inspect(reason)}; " <>
        "retry #{attempts}/#{@max_release_attempts} on a later candidate poll " <>
        "#{State.issue_context(issue)}"
    )

    unless Map.has_key?(state.startup_claim_reconciliation_failures, issue.identifier) do
      emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

      emit_alert_fun.(
        failure_topic(issue),
        issue: issue,
        message: "Startup reconciliation could not release ticket #{issue.identifier}; its orphaned in-progress claim remains.",
        reason:
          "Ticket #{issue.identifier} has no live runtime, but its guarded update from in-progress to todo failed " <>
            "(#{inspect(reason)}); it will be retried up to #{@max_release_attempts} times within this boot.",
        needs_attention: true,
        severity: "warning",
        central: true
      )
    end

    :ok
  end

  defp emit_released_alert(%Issue{} = issue, opts) do
    emit_alert_fun = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

    emit_alert_fun.(
      "ticket.#{issue.identifier}.agent.startup_orphan_claim_released",
      issue: issue,
      message: "Startup reconciliation released ticket #{issue.identifier} from in-progress to todo.",
      reason:
        "Ticket #{issue.identifier} carried an in-progress claim but no live runtime in the current orchestrator " <>
          "registry owned it, so the claim was released by a guarded update.",
      needs_attention: false,
      severity: "warning"
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

  defp retry_exhausted?(%State{} = state, %Issue{identifier: identifier}) do
    case Map.get(state.startup_claim_reconciliation_failures, identifier) do
      %{attempts: attempts} when is_integer(attempts) -> attempts >= @max_release_attempts
      _other -> false
    end
  end

  defp lifecycle_state_name(opts, slug, fallback) do
    opts
    |> Keyword.get_lazy(:active_states, &Config.active_states/0)
    |> Enum.find(fallback, &(DispatchPolicy.state_slug(&1) == slug))
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
end
