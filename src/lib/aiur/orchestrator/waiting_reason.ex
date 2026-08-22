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
          | :run_paused
          | :awaiting_dispatch
          | :paused_operator
          | :paused_transient
          | :latched_lifetime
          | :tracker_unavailable
          | :backing_off
          | :unresponsive
          | :claim_released
          | :active

  @doc """
  Classifies a row backed by a live running process.

  `attrs`:
    * `:tracker_state` — the tracker issue's state string
    * `:pause_reason` — the running entry's `paused_reason` atom, if any
    * `:work_state` — the running entry's `control.status` (`:working` /
      `:paused` / `:sleeping` / `:deactivated`)
    * `:open_decision_count` — unresolved ticket attentions requiring input
    * `:stale_for_seconds` — seconds since last observed agent activity
    * `:stall_timeout_seconds` — `Config.agent_stall_timeout_ms/0` in seconds
  """
  @spec for_running(map()) :: t()
  def for_running(%{} = attrs) do
    tracker_reason = by_tracker_state(Map.get(attrs, :tracker_state))

    cond do
      open_decision?(Map.get(attrs, :open_decision_count)) -> :waiting_for_human
      Map.get(attrs, :work_state) == :completed -> :awaiting_dispatch
      unresponsive?(attrs) -> :unresponsive
      # A duration-capped pause is one consistent state, never re-labelled by
      # whatever the tracker state happens to be. #2310 and #2311 paused for
      # the same `max_agent_duration` reason rendered `waiting_for_human` and
      # `paused` depending on their tracker state; "maximum agent duration
      # reached" is a local pause, not a tracker wait, so it always reads
      # `paused` (an open decision above still wins — it is a separate cause).
      duration_capped_pause?(attrs) -> :paused
      tracker_reason != :active -> tracker_reason
      agent_requested_human?(Map.get(attrs, :pause_reason)) -> :waiting_for_human
      Map.get(attrs, :pause_reason) == :global_pause -> :run_paused
      Map.get(attrs, :work_state) in [:paused, :sleeping] -> :paused
      true -> :active
    end
  end

  defp duration_capped_pause?(%{pause_reason: :max_agent_duration, work_state: :paused}),
    do: true

  defp duration_capped_pause?(_attrs), do: false

  @doc "Every retry-queue row is backing off by definition."
  @spec for_retry() :: t()
  def for_retry, do: :backing_off

  @spec render(t()) :: String.t()
  def render(:waiting_for_human), do: "waiting_for_human"
  def render(:waiting_for_supervisor), do: "waiting_for_supervisor"
  def render(:waiting_for_dependency), do: "waiting_for_dependency"
  def render(:waiting_for_ci), do: "waiting_for_ci"
  def render(:waiting_for_review), do: "waiting_for_review"
  def render(:paused), do: "paused"
  def render(:run_paused), do: "run_paused"
  def render(:awaiting_dispatch), do: "awaiting_dispatch"
  def render(:paused_operator), do: "paused_operator"
  def render(:paused_transient), do: "paused_transient"
  def render(:latched_lifetime), do: "latched_lifetime"
  def render(:tracker_unavailable), do: "tracker_unavailable"
  def render(:backing_off), do: "backing_off"
  def render(:unresponsive), do: "unresponsive"
  def render(:claim_released), do: "claim_released"
  def render(:active), do: "active"
  def render(other), do: to_string(other)

  @doc """
  Classifies a tracker-active row with no live running process.
  An open decision takes precedence, followed by `blocked_by_open?`, which is
  only ever true for a `todo` issue with an unresolved dependency (see
  `DispatchPolicy.todo_issue_blocked_by_non_terminal?/2`).

  The fourth argument is a keyword list of idle-reason evidence so #1457 can
  render *why* a row is idle rather than a bare "idle":

    * `:latched_lifetime` — true when the ticket is held by the lifetime
      dispatch latch (`Dispatcher.dispatch_latch_status/2` != `:none`); not
      resume-clearable
    * `:tracker_paused` — true when the operator's `agent:paused` label
      override is present (`Issue.paused?/1`)
    * `:auto_resume_retry_in_ms` — non-nil when a transient-caused pause/error
      has a pending automatic resume (`Aiur.Orchestrator.AutoResume.retry_in_ms/3`)
    * `:capacity_hold_active?` — true when host-pressure admission is currently
      deferring dispatchable work, so a ready row reads as `:backing_off`
      (capacity) rather than `:active`
    * `:dispatch_hold_reason` — the fleet-wide reason selection did not run;
      `:tracker_preflight` renders an otherwise-ready row as
      `:tracker_unavailable`

  Precedence: an open decision, then a dependency, then the more specific
  #1453 causes (latch > operator pause > pending transient resume), then a
  capacity hold (which only reclassifies the `:active` fallback), then the
  tracker-state classification.
  """
  @spec for_idle(String.t() | nil, boolean(), non_neg_integer(), keyword()) :: t()
  def for_idle(tracker_state, blocked_by_open?, open_decision_count, opts \\ [])

  def for_idle(_tracker_state, _blocked_by_open?, open_decision_count, _opts)
      when open_decision_count > 0, do: :waiting_for_human

  def for_idle(_tracker_state, true, 0, _opts), do: :waiting_for_dependency
  def for_idle(tracker_state, false, 0, opts), do: idle_classification(tracker_state, opts)

  # A lifetime latch wins over a label pause (the latch is not resume-clearable
  # and `resume` cannot move it); an operator pause wins over a pending transient
  # resume (an operator's explicit pause supersedes an automatic one); a
  # capacity hold only reclassifies the `:active` fallback, so it never masks a
  # specific #1453 cause.
  defp idle_classification(tracker_state, opts) do
    cond do
      Keyword.get(opts, :latched_lifetime, false) ->
        :latched_lifetime

      Keyword.get(opts, :tracker_paused, false) ->
        :paused_operator

      Keyword.get(opts, :auto_resume_retry_in_ms) != nil ->
        :paused_transient

      Keyword.get(opts, :dispatch_hold_reason) == :tracker_preflight ->
        dispatch_hold_or_tracker_state(tracker_state)

      Keyword.get(opts, :capacity_hold_active?, false) ->
        capacity_or_tracker_state(tracker_state)

      true ->
        by_tracker_state(tracker_state)
    end
  end

  # A capacity hold only reclassifies dispatchable rows (the `:active` fallback)
  # as `:backing_off`; rows waiting on CI, review, etc. keep their own reason.
  defp capacity_or_tracker_state(tracker_state) do
    case by_tracker_state(tracker_state) do
      :active -> :backing_off
      other -> other
    end
  end

  defp dispatch_hold_or_tracker_state(tracker_state) do
    case by_tracker_state(tracker_state) do
      :active -> :tracker_unavailable
      other -> other
    end
  end

  # Mirrors `Aiur.Orchestrator.RuntimeWatchdog.restart_stalled_issue/5`'s
  # actual exemption set: only `:paused` and `:deactivated` entries are
  # skipped by the stall-restart check there, so a `:sleeping` entry is just
  # as eligible for a stall-triggered kill+retry as a `:working` one — this
  # must classify it the same way, or the dashboard would keep calling it
  # merely "paused" right up to the restart.
  defp unresponsive?(%{
         work_state: work_state,
         stale_for_seconds: stale,
         stall_timeout_seconds: timeout
       })
       when work_state in [:working, :sleeping] and is_integer(stale) and is_integer(timeout) and
              timeout > 0,
       do: stale >= timeout

  defp unresponsive?(_attrs), do: false

  defp open_decision?(count), do: is_integer(count) and count > 0

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
