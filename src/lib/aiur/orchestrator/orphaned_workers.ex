defmodule Aiur.Orchestrator.OrphanedWorkers do
  @moduledoc """
  Stops agent runners that hold a workspace lease no running entry tracks.

  A runner can become untracked in two ways:

    * **Orchestrator restart.** `Aiur.TaskSupervisor` and the workspace
      ownership registry start before the Orchestrator under a `:rest_for_one`
      supervisor, so an Orchestrator crash leaves its runner tasks and their
      leases alive. The restarted Orchestrator starts with an empty running map,
      and each runner still sends its updates to the dead pid (#2705).
    * **Rolled-back state.** A guarded control call that crashes restores the
      Orchestrator state from before the call. A runner the call already spawned
      stays alive, but its running entry is gone.

  Either way a redispatch of the ticket finds the workspace owned and waits for
  a release that never comes. This check runs when the Orchestrator starts and
  on every tick. It stops a runner when all of these are true: its lease is
  provisioning or active, its owner is alive, no running entry has its pid, it
  runs on this host, and its update recipient is this Orchestrator or a dead
  process. A runner that reports to some other live process is left alone.

  The scan reads only the ownership registry (ETS) and never calls a guardian,
  so a guardian that is busy in the ownership store cannot stall a tick.

  The runner is stopped, not adopted. Its update target is fixed at spawn and
  threaded through the whole turn loop, and this Orchestrator has none of the
  running-entry state (session, pane, token totals) that the old entry held.
  The stop follows the normal stop path:

    * the runner task is terminated through `Aiur.TaskSupervisor`, as
      `AgentTeardown.terminate_task/1` does for a tracked runner;
    * the lease guardian observes the owner exit, reaps the provider session it
      recorded (process group, root, descendants), releases the host lock, and
      then releases the lease;
    * the ticket's tracker state stays unchanged, so the redispatch continues
      its in-progress claim instead of releasing and re-claiming it.

  The workspace is kept. Commits and uncommitted edits from the stopped session
  stay in place for the redispatched session.

  A runner on a remote worker host is not stopped. Its guardian cannot prove a
  remote cwd unused after the owner dies, so it would retain the lease forever
  and the ticket would never be redispatched. Such a runner keeps running and
  releases through its own `release_and_wait` when it finishes, as before.

  If no running entry owns the ticket, it is parked in the workspace-ownership
  wait, bound to the stopped generation. A separate process subscribes for the
  release, and the release moves the ticket to the ready set and schedules an
  immediate tick. If a running entry already owns the ticket, that entry's own
  flow redispatches it.

  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.Orchestrator.{AgentTeardown, RetryEngine, State}
  alias Aiur.Workspace.Ownership

  @registry Aiur.Workspace.Ownership.Registry

  @spec stop_untracked_runners(State.t(), keyword()) :: State.t()
  def stop_untracked_runners(%State{} = state, opts \\ []) do
    registry = Keyword.get(opts, :registry, @registry)

    if registry_available?(registry) do
      tracked_pids = tracked_runner_pids(state.running)

      registry
      |> Ownership.holders()
      |> Enum.filter(&untracked?(&1, tracked_pids))
      |> Enum.reduce(state, &stop_if_current(&1, &2, registry))
    else
      state
    end
  end

  defp registry_available?(registry) when is_atom(registry), do: is_pid(Process.whereis(registry))
  defp registry_available?(registry) when is_pid(registry), do: Process.alive?(registry)
  defp registry_available?(_registry), do: false

  defp tracked_runner_pids(running) do
    Enum.reduce(running, MapSet.new(), fn
      {_issue_id, %{pid: pid}}, pids when is_pid(pid) -> MapSet.put(pids, pid)
      _entry, pids -> pids
    end)
  end

  # A tracked runner is rejected on the pid set alone, before any liveness
  # probe. A remote runner is never a candidate (see the moduledoc). A runner
  # that reports to another live process belongs to that process.
  defp untracked?(%{owner: owner, holder: %{issue_id: issue_id, update_recipient: recipient} = holder}, tracked_pids)
       when is_pid(owner) and is_binary(issue_id) and is_pid(recipient) do
    not MapSet.member?(tracked_pids, owner) and not remote?(holder) and Process.alive?(owner) and
      (recipient == self() or not Process.alive?(recipient))
  end

  defp untracked?(_entry, _tracked_pids), do: false

  defp remote?(holder), do: is_binary(Map.get(holder, :worker_host))

  # Confirm against the lease itself: the holder entry must describe the
  # generation that currently owns the ticket, in a phase a live owner holds.
  defp stop_if_current(%{ticket: identifier, generation: generation} = entry, %State{} = state, registry) do
    case Ownership.current(identifier, registry) do
      {:ok, %{generation: ^generation, phase: phase} = lease} when phase in [:provisioning, :active] ->
        stop_runner(state, lease, entry.owner, entry.holder)

      _other ->
        state
    end
  end

  defp stop_runner(%State{} = state, lease, owner, holder) do
    identifier = lease.ticket

    Logger.warning(
      "Stopping an agent runner that holds a workspace lease but has no running entry; it will be redispatched " <>
        "issue_id=#{holder.issue_id} issue_identifier=#{identifier} runner=#{inspect(owner)} " <>
        "update_recipient=#{inspect(holder.update_recipient)} workspace_generation=#{lease.generation}"
    )

    AgentTeardown.close_active_chat_streams(identifier, :replaced)
    AgentTeardown.terminate_task(owner)
    park_until_released(state, lease, holder)
  end

  defp park_until_released(%State{} = state, lease, %{issue_id: issue_id} = holder) do
    if Map.has_key?(state.running, issue_id) or Map.has_key?(state.dispatch_recovery.workspace_ownership.waits, lease.ticket) do
      state
    else
      state =
        RetryEngine.wait_for_workspace_ownership(
          state,
          issue_id,
          lease.ticket,
          {:ok, lease},
          {:bound, lease.guardian, lease.generation},
          %{worker_host: Map.get(holder, :worker_host), prior_work: Config.agent_prior_work_continuation?()}
        )

      subscribe_for_release(lease, self())
      state
    end
  end

  # `Ownership.wait_for_release/2` blocks its caller until the guardian
  # acknowledges, so it runs in its own process. A guardian-bound release is
  # delivered straight to the Orchestrator. If the subscription finds the lease
  # already gone, or bound to another generation, the Orchestrator gets the
  # unbound availability message, which lifts the wait; a later owner then
  # makes the redispatch contend and wait through the normal path.
  defp subscribe_for_release(%{ticket: identifier, guardian: guardian, generation: generation}, orchestrator) do
    spawn(fn ->
      case Ownership.wait_for_release(identifier, orchestrator) do
        {:waiting, ^guardian, ^generation} -> :ok
        _available_or_other -> send(orchestrator, {:workspace_ownership_available, identifier, :none, nil})
      end
    end)

    :ok
  end
end
