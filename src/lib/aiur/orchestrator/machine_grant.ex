defmodule Aiur.Orchestrator.MachineGrant do
  @moduledoc """
  An orchestrator's side of `Aiur.Gateway.Capacity`: the machine headroom it may
  dispatch into, the grant taken when a worker starts, and the per-tick sync that
  hands finished slots back. Without a project context all three are no-ops, so a
  single-project daemon behaves exactly as before.
  """

  alias Aiur.Config
  alias Aiur.Gateway.Capacity
  alias Aiur.Orchestrator.{ControlLifecycle, DispatchPolicy, Slots, State, TelemetryCohort}
  alias Aiur.Project.Context

  @spec headroom() :: :infinity | non_neg_integer()
  def headroom do
    case Context.current_id() do
      nil -> :infinity
      id -> Capacity.headroom(id)
    end
  end

  @spec acquire(term(), String.t() | :none) :: :ok | {:error, :machine_full | :project_full | :yielded | :broker_timeout}
  def acquire(issue_id, feature \\ :none) do
    case Context.current_id() do
      nil -> :ok
      id -> Capacity.acquire(id, issue_id, feature)
    end
  end

  @doc "Runs `start` with a grant for `issue_id`; at the machine or project limit returns `unchanged`."
  @spec granted(term(), State.t(), (-> State.t()), String.t() | :none) :: State.t()
  def granted(issue_id, %State{} = unchanged, start, feature \\ :none) do
    case acquire(issue_id, feature) do
      :ok -> start.()
      {:error, _full} -> unchanged
    end
  end

  @doc """
  Tells the broker how many of `issues` this project could start, so higher-priority
  projects get slots first. Machine headroom is deliberately not counted: a full
  machine must not zero the demand, or a waiting project never reclaims a freed slot.
  Returns `state`.
  """
  @spec report_demand(State.t(), [Aiur.Issue.t()]) :: State.t()
  def report_demand(%State{} = state, issues) do
    with id when id != nil <- Context.current_id() do
      local_free = max(Slots.effective_concurrent_agent_limit(state) - Slots.used_slots(state), 0)

      ready =
        issues
        |> Enum.filter(&(DispatchPolicy.dispatch_candidate_decision(&1, state) == :dispatch and DispatchPolicy.state_slots_available?(&1, state)))
        |> Enum.frequencies_by(&feature/1)

      Capacity.report_demand(id, cap(ready, local_free), feature_order())
    end

    state
  end

  @doc "The ticket's feature: its first `feature:<slug>` label in sorted order, else `:none`."
  @spec feature(Aiur.Issue.t()) :: String.t() | :none
  def feature(%Aiur.Issue{} = issue), do: TelemetryCohort.feature_slug(issue)

  # The project's local free slots bound its total demand; trim features from the lowest-ranked end.
  defp cap(ready, free) do
    order = feature_order()
    ranked = Enum.sort_by(ready, fn {f, _} -> {f == :none, Enum.find_index(order, &(&1 == f)) || length(order), to_string(f)} end)

    {kept, _} =
      Enum.map_reduce(ranked, free, fn {f, n}, left -> {{f, min(n, left)}, left - min(n, left)} end)

    Map.new(kept)
  end

  defp feature_order do
    case Config.settings() do
      {:ok, %{build_order: %{feature_order: order}}} when is_list(order) -> order
      _ -> []
    end
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
