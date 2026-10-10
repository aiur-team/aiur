defmodule Aiur.Orchestrator.StatusReport.RowFacts do
  @moduledoc false
  # Row facts shared by the snapshot payload, running summaries and status rows.

  alias Aiur.CodingAgent
  alias Aiur.Commands
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.State

  @doc false
  @spec visible_polled_issues(State.t()) :: map()
  def visible_polled_issues(%State{candidate_snapshot_fresh?: false}), do: %{}
  def visible_polled_issues(%State{} = state), do: state.last_polled_issues

  @doc false
  @spec capacity_hold_active?(State.t()) :: boolean()
  def capacity_hold_active?(%State{} = state) do
    match?(%{signal: _signal}, state.capacity_hold)
  end

  @doc false
  @spec session_execution(map()) :: map()
  def session_execution(entry) when is_map(entry) do
    case Map.get(entry, :session_execution) do
      execution when is_map(execution) -> execution
      _execution -> %{}
    end
  end

  @doc false
  @spec stale_for_seconds(map(), DateTime.t()) :: non_neg_integer() | nil
  def stale_for_seconds(metadata, %DateTime{} = now) do
    case Map.get(metadata, :last_codex_timestamp) || Map.get(metadata, :started_at) do
      %DateTime{} = last_activity -> max(0, DateTime.diff(now, last_activity, :second))
      _ -> nil
    end
  end

  @doc false
  @spec stall_timeout_seconds() :: non_neg_integer()
  def stall_timeout_seconds do
    case Config.agent_stall_timeout_ms() do
      0 -> 0
      timeout_ms -> div(timeout_ms + 999, 1_000)
    end
  end

  @doc false
  @spec open_decision_count(term()) :: {non_neg_integer(), :available | :unavailable}
  def open_decision_count(identifier) when is_binary(identifier) do
    case Commands.open_blocking_decision_ids([identifier], Commands.default_store(), 100) do
      {:ok, ids} -> {length(ids), :available}
      {:error, :store_unavailable} -> {0, :unavailable}
    end
  end

  def open_decision_count(_identifier), do: {0, :unavailable}

  # Highest `complexity:N` label on the issue (nil when unlabelled). Reused by
  # the status rows so `aiur watch` can render the cx column without a tracker
  # round-trip — the issue is already in memory.
  @doc false
  @spec issue_complexity(term()) :: term()
  def issue_complexity(%Issue{} = issue), do: CodingAgent.complexity_level(issue)
  def issue_complexity(_issue), do: nil

  @doc false
  @spec startup_work_state(map()) :: atom()
  def startup_work_state(entry) do
    case get_in(entry, [:control, :status]) || :working do
      :working -> if(is_nil(Map.get(entry, :session_id)), do: :starting, else: :working)
      other -> other
    end
  end

  @doc false
  @spec retry_snapshot_tracker_identity(map(), Issue.t() | nil) :: term()
  def retry_snapshot_tracker_identity(retry, nil), do: Map.get(retry, :tracker_identity)
  def retry_snapshot_tracker_identity(_retry, issue), do: Issue.tracker_identity(issue)

  # Distinguishes "this issue has no upstreams" from "we never resolved this
  # issue". Only the first is an empty list; the second is `nil`, which
  # `StreamDeckGrid.dependency_ready?/2` treats as blocking. Defaulting the
  # unknown case to `[]` would read as "no dependencies" and render the key
  # `Unblocked` — the same fail-open this projection exists to remove.
  @doc false
  @spec known_blocked_by(term()) :: list() | nil
  def known_blocked_by(%Issue{blocked_by: blockers}) when is_list(blockers), do: blockers
  def known_blocked_by(_issue), do: nil

  @doc false
  @spec idle_issue_work_state(term()) :: :paused | :idle
  def idle_issue_work_state(%Issue{} = issue) do
    if Issue.paused?(issue), do: :paused, else: :idle
  end

  def idle_issue_work_state(_issue), do: :idle

  @doc false
  @spec idle_issue_pause_reason(term()) :: :label_override | nil
  def idle_issue_pause_reason(%Issue{} = issue) do
    if Issue.paused?(issue), do: :label_override, else: nil
  end

  def idle_issue_pause_reason(_issue), do: nil
end
