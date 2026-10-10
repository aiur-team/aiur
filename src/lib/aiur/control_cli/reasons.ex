defmodule Aiur.ControlCLI.Reasons do
  @moduledoc false

  @doc false
  @spec format_reason(term()) :: String.t()
  def format_reason({:stale_tracker_state, reason, details}) do
    changed_context =
      case Map.get(details, :changed_fields, []) do
        [] -> ""
        fields -> ", changed=#{Enum.join(fields, ",")}"
      end

    paused_context =
      if Map.get(details, :cached_paused) != Map.get(details, :tracker_paused) do
        ", cached_paused=#{details.cached_paused}, tracker_paused=#{details.tracker_paused}"
      else
        ""
      end

    "tracker cache was stale: cached=#{details.cached_state}, tracker=#{details.tracker_state}#{changed_context}#{paused_context}; #{format_reason(reason)}"
  end

  def format_reason({:tracker_state_not_resumable, state}),
    do: "tracker state #{state} is not resumable"

  def format_reason({:tracker_refresh_failed, reason}),
    do: "tracker refresh failed: #{format_reason(reason)}"

  def format_reason({:budget_reset_failed, reason}),
    do: "durable budget reset failed: #{format_reason(reason)}"

  def format_reason({:state_restore_failed, reason}),
    do: "tracker state restore failed: #{format_reason(reason)}"

  def format_reason({:state_concurrency_limit_reached, state}),
    do: "state concurrency limit reached for #{state}"

  def format_reason({:blocked_on_decision, %{decision_ids: [_ | _] = ids}}),
    do: "ticket is held by open blocking decision #{Enum.join(ids, ", ")}; answer it (see `aiurdev commands`), then resume"

  def format_reason({:blocked_on_decision, %{store: :unavailable}}),
    do: "ticket is held because the decision store could not be read, so an open blocking decision cannot be ruled out; retry after the store recovers"

  def format_reason({:blocked_on_decision, _detail}),
    do: "ticket is held by an open blocking decision; answer it (see `aiurdev commands`), then resume"

  def format_reason({:worker_startup_failed, reason}),
    do: "the agent's worker failed to start (#{inspect(reason, limit: 10, printable_limit: 200)}); resume does not start a second worker, the retry schedule restarts it (see `aiurdev status`)"

  def format_reason({:not_resumable_control_status, status}),
    do: "the agent is in control state #{status}, which resume cannot act on"

  def format_reason({:unmapped_dispatch_decline, reason}),
    do: "dispatch declined the ticket (#{inspect(reason)}); inspect `aiurdev status` and the daemon log"

  def format_reason({:control_call_crashed, action, summary}),
    do: "the orchestrator hit an internal error handling #{action} (#{summary}); the agent registry was kept, see the daemon log"

  # Keep the real fault visible instead of collapsing it to a cause the CLI
  # has not established (#1634).
  def format_reason({:orchestrator_call_failed, reason}),
    do: "orchestrator call failed: #{inspect(reason)}"

  def format_reason({:dispatch_failed, :no_worker_capacity}),
    do: "dispatch failed because no worker capacity is available; retry after a worker slot is free"

  def format_reason({:dispatch_failed, :state_capacity}),
    do: "dispatch failed because this ticket state is at capacity; retry after an agent in the same state finishes"

  def format_reason({:dispatch_failed, :fleet_capacity}),
    do: "dispatch failed because the fleet is at max concurrent agent capacity; retry after an agent slot is free"

  def format_reason({:dispatch_failed, :all_backends_usage_limited}),
    do: "dispatch failed because every configured backend is usage-limited; retry after a provider limit resets"

  def format_reason({:dispatch_failed, :thrash_circuit_open}),
    do: "dispatch failed because the restart circuit is open; retry after the restart window resets or run `aiurdev reset-budget <id>`"

  def format_reason({:dispatch_failed, {:dispatch_declined, reason}}),
    do: "dispatch was declined (#{inspect(reason)}); retry after the ticket state, labels, or tracker visibility becomes dispatchable"

  def format_reason({:dispatch_failed, {:worker_start_failed, reason}}),
    do: "dispatch failed while starting the worker (#{inspect(reason)}); inspect the daemon alert and retry after the worker failure clears"

  def format_reason({:dispatch_failed, :cause_unknown}),
    do: "dispatch failed, but the daemon could not determine the cause; inspect `aiurdev alerts` and the daemon log before retrying"

  def format_reason({:dispatch_failed, reason}),
    do: "dispatch failed for #{inspect(reason)}, but the daemon could not determine what clears it; inspect `aiurdev alerts` and the daemon log before retrying"

  def format_reason({:redispatch_deferred, :max_concurrent_agents_reached}),
    do: "redispatch deferred by max concurrent agent capacity; it clears when an agent slot is free"

  def format_reason({:redispatch_deferred, :no_worker_capacity}),
    do: "redispatch deferred because no worker capacity is available; it clears when a worker slot is free"

  def format_reason({:redispatch_deferred, :preferred_worker_unavailable}),
    do: "redispatch deferred because the preferred worker is not selectable for this backend; it clears when a compatible worker is available or routing selects a compatible backend"

  def format_reason({:redispatch_deferred, :thrash_circuit_open}),
    do: "redispatch deferred by the restart circuit; it clears when the restart window resets or `reset-budget` clears the latch"

  def format_reason({:redispatch_deferred, {:all_limited, backends}}),
    do: "redispatch deferred because every fallback backend is usage-limited (#{Enum.join(backends, ", ")}); it clears after a provider limit resets"

  def format_reason({:redispatch_deferred, {:unknown_backend, backend}}),
    do: "redispatch deferred because backend #{inspect(backend)} is not configured; it clears after the ticket selects a configured backend"

  def format_reason({:redispatch_deferred, {:not_dispatchable, reason}}),
    do: "redispatch deferred because the refreshed ticket is not dispatchable (#{inspect(reason)}); it clears after its state, labels, or blockers become eligible"

  def format_reason({:redispatch_deferred, :missing_after_revalidation}),
    do: "redispatch deferred because the ticket disappeared during tracker revalidation; retry after tracker visibility is restored"

  def format_reason({:redispatch_deferred, {:tracker_revalidation_failed, reason}}),
    do: "redispatch deferred because tracker revalidation failed (#{inspect(reason)}); it clears after tracker access recovers"

  def format_reason({:redispatch_deferred, {:worker_start_failed, reason}}),
    do: "redispatch was admitted but the replacement worker failed to start (#{inspect(reason)}); it clears after the worker startup failure is repaired"

  def format_reason({:redispatch_deferred, :cause_unknown}),
    do: "redispatch was admitted but no replacement worker started; the cause and clearing condition could not be determined, so inspect `aiurdev alerts` and the daemon log before retrying"

  def format_reason({:redispatch_deferred, reason}),
    do: "redispatch deferred for #{inspect(reason)}; what clears it could not be determined, so inspect `aiurdev alerts` and the daemon log before retrying"

  def format_reason(reason) do
    Map.get(
      %{
        no_running_agent: "no running agent",
        agent_finished: "agent finished",
        max_concurrent_agents_reached: "max concurrent agents reached",
        below_active_count: "below active agent count",
        not_resumable: "not resumable",
        empty_message: "message is empty",
        message_too_long: "message is too long",
        invalid_message: "invalid message",
        unavailable: "orchestrator unavailable",
        not_found: "workspace ownership hold not found",
        invalid_ticket_identifier: "invalid ticket identifier",
        orchestrator_unavailable: "orchestrator unavailable",
        timeout: "orchestrator timed out",
        unknown_issue: "unknown issue",
        tracker_issue_not_found: "tracker issue not found",
        invalid_tracker_issue: "tracker returned an invalid issue",
        contradictory_tracker_state_labels: "tracker returned contradictory state labels",
        not_routable_to_worker: "ticket is not routable to a worker",
        dispatch_not_authorized: "tracker label provenance does not authorize dispatch",
        pause_override_still_present: "tracker pause override is still present",
        ticket_parked: "ticket is parked from fleet dispatch; unpark it, then resume",
        worker_not_running: "the agent is registered as working but its worker process is gone; the next poll reconciles it, then resume",
        worker_not_started: "the agent's replacement worker is still starting; retry once it is running",
        waiting_for_dependencies: "ticket is waiting for dependencies",
        already_claimed: "ticket is already claimed for dispatch",
        auto_resume_pending: "ticket already has a scheduled automatic resume",
        workspace_ownership_waiting: "ticket is waiting for workspace ownership recovery",
        no_worker_capacity: "no worker capacity",
        dispatch_retry_scheduled: "dispatch failed and a retry was scheduled",
        all_model_backends_limited: "all configured model backends are usage-limited",
        thrash_circuit_open: "dispatch restart circuit is open",
        dispatch_not_started: "dispatch did not start; inspect the ticket attention feed",
        lifetime_dispatch_latch: "lifetime dispatch latch (run `aiurdev reset-budget <id>` to clear; resume cannot)",
        dispatch_failed: "dispatch failed"
      },
      reason,
      inspect(reason)
    )
  end

  @doc false
  @spec format_message_reason(term()) :: String.t()
  def format_message_reason(:agent_finished), do: "agent is not accepting messages (agent finished)"
  def format_message_reason(:immediate_not_supported), do: "agent is not accepting immediate messages"
  def format_message_reason(:interrupt_not_supported), do: "agent is not accepting interrupt messages"
  def format_message_reason({:not_queued, :timeout}), do: "the daemon timed out and did not queue it; a retry is safe"

  def format_message_reason({:message_id_conflict, _item_id}),
    do: "that --message-id was already used for a different message; use a new id"

  def format_message_reason(reason), do: format_reason(reason)
end
