defmodule Aiur.Orchestrator.TelemetryEvents do
  @moduledoc """
  Records the ticket transitions only the daemon's poll diff can see.

  `Aiur.Orchestrator.IssueSync` calls `observe/3` with the previous and current
  polled issue. State changes are recorded whichever writer made them (comment
  wake, human-review revert, Executor label edit), blocker clearance lands on
  the dependent, and terminal membership schedules usage capture.
  Every call is fail-open and returns the orchestrator state unchanged.
  """

  alias Aiur.Issue
  alias Aiur.Orchestrator.{CapacityBinding, DispatchPolicy, IssueSync}
  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Lifecycle

  @spec observe(term(), Issue.t() | nil, Issue.t(), keyword()) :: term()
  def observe(state, previous_issue, issue, opts \\ [])

  def observe(state, %Issue{} = previous, %Issue{} = issue, opts) do
    if Lifecycle.enabled?(opts) do
      record_state_change(state, previous, issue, opts)
      record_cleared_blockers(previous, issue, opts)
    end

    state
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  def observe(state, _previous, _issue, _opts), do: state

  defp record_state_change(state, previous, issue, opts) do
    from = DispatchPolicy.state_slug(previous.state)
    to = DispatchPolicy.state_slug(issue.state)

    if is_binary(from) and is_binary(to) and from != to do
      attempt_id =
        case Map.get(state.running, issue.id) do
          %{telemetry_attempt_id: id} -> id
          _other -> nil
        end

      Lifecycle.record(issue.identifier, attempt_id, :state_change, :point, %{from_state: from, to_state: to, cause: :observed}, opts)
    end
  end

  defp record_cleared_blockers(previous, issue, opts) do
    previous_blockers = IssueSync.blocker_map(previous)
    current_blockers = IssueSync.blocker_map(issue)

    for {id, blocker} <- previous_blockers, cause = clearance_cause(blocker, Map.get(current_blockers, id)) do
      Lifecycle.record(issue.identifier, nil, :dependency_cleared, :point, %{blocker: blocker_identifier(blocker, id), cause: cause}, opts)
    end
  end

  defp clearance_cause(_previous, nil), do: :removed

  defp clearance_cause(previous, current) do
    if not terminal?(previous) and terminal?(current), do: :terminal
  end

  defp terminal?(%{state: state}), do: DispatchPolicy.terminal_issue_state?(state, DispatchPolicy.terminal_state_set())
  defp terminal?(_blocker), do: false

  defp blocker_identifier(blocker, id), do: Map.get(blocker, :identifier) || Map.get(blocker, "identifier") || id

  @spec terminal(Issue.t(), atom()) :: :ok
  def terminal(issue, lifecycle) when lifecycle in [:completed, :cancelled] do
    RunTelemetry.capture_usage(issue.identifier, Issue.tracker_identity(issue))
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  def terminal(_issue, _lifecycle), do: :ok

  @spec binding_snapshot(term()) :: term()
  def binding_snapshot({:current, %{capacity: capacity} = snapshot, freshness}) do
    {kind, _detail} = CapacityBinding.binding(capacity, Map.get(snapshot, :polling, %{}))
    {:current, Map.put(snapshot, :fleet_binding_kind, Atom.to_string(kind)), freshness}
  end

  def binding_snapshot(other), do: other
end
