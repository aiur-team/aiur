defmodule Aiur.Orchestrator.WaitingReason.Owners do
  @moduledoc "JSON-safe names of the part that can clear each `Aiur.Orchestrator.WaitingReason`."

  @owners %{
    waiting_for_human: "Executor",
    waiting_for_supervisor: "Executor",
    waiting_for_dependency: "DispatchPolicy",
    queue_set_order: "DispatchPolicy",
    optimistic_share: "DispatchPolicy",
    waiting_for_ci: "CiLifecycle",
    waiting_for_review: "Executor",
    paused: "PauseResume",
    run_paused: "PauseResume",
    awaiting_dispatch: "Dispatcher",
    paused_operator: "PauseResume",
    parked: "Executor",
    paused_transient: "AutoResume",
    provider_limited: "RateLimitFallback",
    latched_lifetime: "Dispatcher",
    tracker_unavailable: "Dispatcher",
    backing_off: "RetryEngine",
    unresponsive: "RuntimeWatchdog",
    claim_released: "AutoResume",
    orphaned_claim: "StartupClaimReconciler",
    stale_claim: "Reconciler",
    workspace_ownership_waiting: "Workspace.Ownership",
    workspace_retained: "Workspace.Ownership",
    active: "AgentRunner"
  }

  @spec fetch!(atom()) :: String.t()
  def fetch!(reason), do: Map.fetch!(@owners, reason)
end
