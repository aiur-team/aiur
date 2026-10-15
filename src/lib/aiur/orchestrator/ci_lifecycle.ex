defmodule Aiur.Orchestrator.CiLifecycle do
  @moduledoc """
  Coordinates tracker transitions, runner control, and terminal events for CI.
  Tracker reads and writes run outside the orchestrator; results update current state.
  """

  alias Aiur.CIApprovalStore
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle.Poll
  alias Aiur.Orchestrator.CiLifecycle.TerminalEvent
  alias Aiur.Orchestrator.CiLifecycle.Transition
  alias Aiur.Orchestrator.CiLifecycle.WaitRewake
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.RestackScheduler
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.PollCadence
  alias Aiur.Tracker

  @ci_wait_state "ci-wait"

  @spec poll_github_ci(State.t(), keyword()) :: State.t()
  def poll_github_ci(%State{} = state, opts \\ []) do
    state = RestackScheduler.reconcile(state, [])

    case Config.tracker_kind() do
      # See `CommentPolling.poll_github_comments/2`: CI polling also keeps the
      "github" ->
        if within_ci_cadence?(state, System.monotonic_time(:millisecond)) do
          state
        else
          do_poll_github_ci(state, opts)
        end

      _ ->
        state
    end
  end

  # CI cadence binds only during continuous demand; newly waiting PRs poll promptly (#2309).
  #
  # Default CI cadence follows dispatch; it slows only when an operator sets
  # `intervals.ci` wider than the tick — which is deliberately *not* the
  # recommended shape (#2309): CI staleness has agent-visible consequences, so
  # keep `ci` at or below `dispatch`.
  defp within_ci_cadence?(state, now_ms) do
    PollCadence.within_class_cadence?(state.last_ci_poll_started_at_ms, now_ms, :ci)
  end

  @spec maybe_resume_for_ci_failure(State.t(), String.t()) :: State.t()
  def maybe_resume_for_ci_failure(%State{} = state, identifier) when is_binary(identifier) do
    maybe_resume_for_ci_terminal(state, identifier, :failed)
  end

  @spec maybe_resume_for_ci_terminal(State.t(), String.t(), :passed | :failed) :: State.t()
  def maybe_resume_for_ci_terminal(%State{} = state, identifier, outcome)
      when is_binary(identifier) and outcome in [:passed, :failed] do
    case State.find_running_by_identifier(state.running, identifier) do
      %{control: %{status: status}, paused_reason: :ci_wait} = running_entry
      when status in [:paused, :deactivated] ->
        WaitRewake.revalidate_ci_terminal_wake(
          state,
          running_entry,
          identifier,
          outcome,
          &Tracker.fetch_issue_states_by_ids/1
        )

      _ ->
        state
    end
  end

  @spec ci_wait_state?(term()) :: boolean()
  def ci_wait_state?(state_name) when is_binary(state_name) do
    DispatchPolicy.normalize_issue_state(state_name) == @ci_wait_state
  end

  def ci_wait_state?(_state_name), do: false

  @doc false
  @spec ci_target_for_issue(Issue.t() | term()) :: String.t() | nil
  def ci_target_for_issue(%Issue{identifier: identifier})
      when is_binary(identifier) and identifier != "",
      do: identifier

  def ci_target_for_issue(%Issue{id: id}) when is_binary(id) and id != "", do: id
  def ci_target_for_issue(_issue), do: nil

  @doc false
  @spec transition_ci_ticket(State.t(), Issue.t(), String.t()) :: State.t()
  defdelegate transition_ci_ticket(state, issue, next_state), to: Transition

  @doc false
  @spec pause_issue_for_ci_wait(State.t(), Issue.t()) :: State.t()
  defdelegate pause_issue_for_ci_wait(state, issue), to: Transition

  @doc false
  @spec arm_ci_wait_rewake(State.t(), Issue.t()) :: State.t()
  defdelegate arm_ci_wait_rewake(state, issue), to: WaitRewake

  @doc false
  @spec cancel_ci_wait_rewake(State.t(), String.t() | nil) :: State.t()
  defdelegate cancel_ci_wait_rewake(state, issue_id), to: WaitRewake

  @doc false
  @spec handle_ci_wait_rewake(State.t(), String.t(), reference(), keyword()) :: State.t()
  defdelegate handle_ci_wait_rewake(state, issue_id, token, opts \\ []), to: WaitRewake

  @doc false
  @spec clear_ci_approved_head(State.t(), Issue.t()) :: State.t()
  def clear_ci_approved_head(%State{} = state, %Issue{} = issue) do
    case ci_target_for_issue(issue) do
      target when is_binary(target) ->
        approved_heads = Map.delete(state.ci_lifecycle.approved_heads, target)

        persist_ci_lifecycle_state(%{
          state
          | ci_lifecycle:
              state.ci_lifecycle
              |> Map.put(:approved_heads, approved_heads)
              |> Map.update(:passed_heads, %{}, &Map.delete(&1, target))
        })

      _ ->
        state
    end
  end

  @doc false
  @spec persist_ci_lifecycle_state(State.t()) :: State.t()
  def persist_ci_lifecycle_state(%State{} = state) do
    :ok =
      CIApprovalStore.save(
        state.ci_lifecycle.approved_heads,
        state.ci_lifecycle.test_failure_heads,
        Map.get(state.ci_lifecycle, :base_repair_invalidations, %{}),
        Map.get(state.ci_lifecycle, :passed_heads, %{})
      )

    state
  end

  @doc false
  @spec publish_ci_terminal_event(State.t(), Issue.t(), map(), :passed | :failed) :: State.t()
  defdelegate publish_ci_terminal_event(state, issue, result, outcome), to: TerminalEvent

  @doc false
  @spec start_poll(State.t(), (State.t() -> State.t()), keyword()) :: State.t()
  def start_poll(%State{} = state, continue, opts \\ []) do
    if Config.tracker_kind() == "github" and not within_ci_cadence?(state, System.monotonic_time(:millisecond)) do
      Poll.launch_ci_poll(state, Keyword.put_new(opts, :ci_recovery_poll_id, make_ref()), continue, &TrackerTasks.start/4)
    else
      continue.(state)
    end
  end

  defp do_poll_github_ci(state, opts) do
    Poll.launch_ci_poll(state, Keyword.put_new(opts, :ci_recovery_poll_id, make_ref()), &Function.identity/1, &TrackerTasks.run/4)
  end
end
