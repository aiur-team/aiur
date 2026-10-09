defmodule Aiur.Orchestrator.StartupClaimReconciler.Observation do
  @moduledoc false

  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchPolicy, State}
  alias Aiur.Workspace.Ownership

  @grace_ms 60_000

  @spec observe(State.t(), [Issue.t()], keyword()) :: State.t()
  def observe(state, issues, opts) do
    now = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))
    since = Map.new(Enum.filter(issues, &orphan?(state, &1, opts)), &{&1.identifier, Map.get(state.orphaned_claim_since, &1.identifier, now)})
    %{state | orphaned_claim_since: since}
  end

  @spec expired?(State.t(), Issue.t(), keyword()) :: boolean()
  def expired?(state, issue, opts) do
    now = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))
    now - Map.fetch!(state.orphaned_claim_since, issue.identifier) >= Keyword.get(opts, :grace_ms, @grace_ms)
  end

  @spec dispatch_candidates(State.t(), [Issue.t()]) :: [Issue.t()]
  def dispatch_candidates(state, issues) do
    Enum.reject(issues, &(DispatchPolicy.state_slug(&1.state) == "in-progress" and Map.has_key?(state.orphaned_claim_since, &1.identifier)))
  end

  defp orphan?(state, issue, opts) do
    DispatchPolicy.state_slug(issue.state) == "in-progress" and is_binary(issue.identifier) and
      not Issue.paused?(issue) and not Issue.parked?(issue) and not tracked?(state, issue) and lease_free?(issue, opts)
  end

  defp tracked?(state, issue) do
    Enum.any?(state.running, fn {_id, entry} ->
      entry[:identifier] == issue.identifier and (is_nil(entry[:pid]) or State.alive?(entry[:pid]))
    end) or Map.has_key?(state.retry_attempts, issue.id) or Map.has_key?(state.auto_resume, issue.id) or
      Map.has_key?(state.dispatch_recovery.workspace_ownership.waits, issue.identifier) or
      Map.has_key?(state.dispatch_recovery.workspace_ownership.ready, issue.identifier)
  end

  @spec lease_free?(Issue.t(), keyword()) :: boolean()
  def lease_free?(issue, opts) do
    lookup = Keyword.get(opts, :ownership_fun, &current_lease/1)
    lookup.(issue.identifier) == :none
  end

  defp current_lease(identifier) do
    if Process.whereis(Aiur.Workspace.Ownership.Registry), do: Ownership.current(identifier), else: :none
  end
end
