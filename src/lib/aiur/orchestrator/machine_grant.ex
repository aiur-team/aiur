defmodule Aiur.Orchestrator.MachineGrant do
  @moduledoc """
  An orchestrator's side of `Aiur.Gateway.Capacity`: the machine headroom it may
  dispatch into, the grant taken when a worker starts, and the per-tick sync that
  hands finished slots back. Without a project context all three are no-ops, so a
  single-project daemon behaves exactly as before.
  """

  alias Aiur.Gateway.Capacity
  alias Aiur.Orchestrator.{ControlLifecycle, DispatchPolicy, State}
  alias Aiur.Project.Context

  @spec headroom() :: :infinity | non_neg_integer()
  def headroom do
    case Context.current_id() do
      nil -> :infinity
      id -> Capacity.headroom(id)
    end
  end

  @spec acquire(term()) :: :ok | {:error, :machine_full | :project_full}
  def acquire(issue_id) do
    case Context.current_id() do
      nil -> :ok
      id -> Capacity.acquire(id, issue_id)
    end
  end

  @doc "Runs `start` with a grant for `issue_id`; at the machine or project limit returns `unchanged`."
  @spec granted(term(), State.t(), (-> State.t())) :: State.t()
  def granted(issue_id, %State{} = unchanged, start) do
    case acquire(issue_id) do
      :ok -> start.()
      {:error, _full} -> unchanged
    end
  end

  @doc "Tells the broker how many of `issues` dispatch would start, so higher-priority projects get slots first. Returns `state`."
  @spec report_demand(State.t(), [Aiur.Issue.t()]) :: State.t()
  def report_demand(%State{} = state, issues) do
    with id when id != nil <- Context.current_id() do
      Capacity.report_demand(id, Enum.count(issues, &DispatchPolicy.should_dispatch_issue?(&1, state)))
    end

    state
  end

  @spec sync(State.t()) :: :ok
  def sync(%State{} = state) do
    case Context.current_id() do
      nil -> :ok
      id -> Capacity.sync(id, holder_ids(state))
    end
  end

  @doc "Issue ids occupying a slot: the same classes `Slots.used_slots/1` counts."
  @spec holder_ids(State.t()) :: [term()]
  def holder_ids(%State{} = state) do
    running = for {id, entry} <- state.running, holds?(state, id, entry), do: id
    claims = for {_ref, %{key: {:rework_claim, id}}} <- tasks(state), do: id
    Enum.uniq(running ++ claims)
  end

  defp holds?(state, id, entry) do
    one = %{id => entry}

    State.active_running_count(one) + State.reserved_paused_running_count(one) > 0 or
      (State.paused_running_entry?(entry) and match?(%{action: :resume}, ControlLifecycle.current_pending(state.control_lifecycle, id)))
  end

  defp tasks(%State{tracker_tasks: tasks}) when is_map(tasks), do: tasks
  defp tasks(_state), do: %{}
end
