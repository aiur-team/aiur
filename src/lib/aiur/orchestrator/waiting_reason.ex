defmodule Aiur.Orchestrator.WaitingReason do
  @moduledoc """
  Derives one explicit fleet-row waiting reason for OCC-5. Every branch names
  a concrete cause or `:active` — never a generic "blocked".

  Pure and orchestrator-state-free by design: callers (`StatusReport`,
  `Presenter`) extract the handful of fields each classification needs from
  live state so this module stays trivially unit-testable.
  """

  @type t ::
          :waiting_for_human
          | :waiting_for_supervisor
          | :waiting_for_dependency
          | :waiting_for_ci
          | :waiting_for_review
          | :paused
          | :backing_off
          | :unresponsive
          | :active

  @doc """
  Classifies a row backed by a live running process.

  `attrs`:
    * `:tracker_state` — the tracker issue's state string
    * `:pause_reason` — the running entry's `paused_reason` atom, if any
    * `:work_state` — the running entry's `control.status` (`:working` /
      `:paused` / `:sleeping` / `:deactivated`)
    * `:stale_for_seconds` — seconds since last observed agent activity
    * `:stall_timeout_seconds` — `Config.agent_stall_timeout_ms/0` in seconds
  """
  @spec for_running(map()) :: t()
  def for_running(%{} = attrs) do
    tracker_reason = by_tracker_state(Map.get(attrs, :tracker_state))

    cond do
      unresponsive?(attrs) -> :unresponsive
      tracker_reason != :active -> tracker_reason
      agent_requested_human?(Map.get(attrs, :pause_reason)) -> :waiting_for_human
      Map.get(attrs, :work_state) in [:paused, :sleeping] -> :paused
      true -> :active
    end
  end

  @doc "Every retry-queue row is backing off by definition."
  @spec for_retry() :: t()
  def for_retry, do: :backing_off

  @doc """
  Classifies a tracker-active row with no live running process.
  `blocked_by_open?` takes precedence — it is only ever true for a `todo`
  issue with an unresolved dependency (see `DispatchPolicy.todo_issue_blocked_by_non_terminal?/2`).
  """
  @spec for_idle(String.t() | nil, boolean()) :: t()
  def for_idle(tracker_state, blocked_by_open?)
  def for_idle(_tracker_state, true), do: :waiting_for_dependency
  def for_idle(tracker_state, false), do: by_tracker_state(tracker_state)

  defp unresponsive?(%{work_state: :working, stale_for_seconds: stale, stall_timeout_seconds: timeout})
       when is_integer(stale) and is_integer(timeout) and timeout > 0,
       do: stale >= timeout

  defp unresponsive?(_attrs), do: false

  defp agent_requested_human?(reason), do: reason in [:agent_pause_request, :input_required]

  defp by_tracker_state(state) when is_binary(state) do
    case state |> String.downcase() |> String.trim() do
      "ci-wait" -> :waiting_for_ci
      "human-review" -> :waiting_for_review
      "rework" -> :waiting_for_human
      "merging" -> :waiting_for_supervisor
      _ -> :active
    end
  end

  defp by_tracker_state(_state), do: :active
end
