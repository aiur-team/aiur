defmodule Aiur.Orchestrator.WaitingReasonTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.WaitingReason

  describe "for_running/1" do
    test "completed runners are awaiting replacement dispatch" do
      assert WaitingReason.for_running(%{
               tracker_state: "rework",
               pause_reason: nil,
               work_state: :completed,
               open_decision_count: 0,
               stale_for_seconds: 0,
               stall_timeout_seconds: 300
             }) == :awaiting_dispatch
    end

    test "an actively working agent with fresh activity is active" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: nil,
               work_state: :working,
               stale_for_seconds: 5,
               stall_timeout_seconds: 3600
             }) == :active
    end

    test "a working agent past the stall timeout is unresponsive" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: nil,
               work_state: :working,
               stale_for_seconds: 3601,
               stall_timeout_seconds: 3600
             }) == :unresponsive
    end

    test "an open decision takes precedence over tracker state and staleness" do
      assert WaitingReason.for_running(%{
               tracker_state: "human-review",
               pause_reason: nil,
               work_state: :working,
               open_decision_count: 1,
               stale_for_seconds: 3601,
               stall_timeout_seconds: 3600
             }) == :waiting_for_human
    end

    test "a deliberately paused agent is never classified as unresponsive" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: :operator_pause,
               work_state: :paused,
               stale_for_seconds: 999_999,
               stall_timeout_seconds: 3600
             }) == :paused
    end

    test "a globally-paused agent is classified as run_paused, distinct from an individual pause" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: :global_pause,
               work_state: :paused,
               stale_for_seconds: 999_999,
               stall_timeout_seconds: 3600
             }) == :run_paused

      # An operator's own pause stays :paused, so the two causes remain distinguishable.
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: :operator_pause,
               work_state: :paused
             }) == :paused
    end

    test "a zero stall timeout never triggers unresponsive" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: nil,
               work_state: :working,
               stale_for_seconds: 999_999,
               stall_timeout_seconds: 0
             }) == :active
    end

    test "ci_wait pause reason maps to waiting_for_ci" do
      assert WaitingReason.for_running(%{
               tracker_state: "ci-wait",
               pause_reason: :ci_wait,
               work_state: :paused,
               stale_for_seconds: 10,
               stall_timeout_seconds: 3600
             }) == :waiting_for_ci
    end

    test "tracker state ci-wait wins even without a live pause_reason (deactivated entry)" do
      assert WaitingReason.for_running(%{
               tracker_state: "ci-wait",
               pause_reason: nil,
               work_state: :deactivated,
               stale_for_seconds: nil,
               stall_timeout_seconds: 3600
             }) == :waiting_for_ci
    end

    test "tracker state human-review maps to waiting_for_review" do
      assert WaitingReason.for_running(%{
               tracker_state: "human-review",
               pause_reason: nil,
               work_state: :deactivated,
               stale_for_seconds: nil,
               stall_timeout_seconds: 3600
             }) == :waiting_for_review
    end

    test "tracker state rework maps to waiting_for_human" do
      assert WaitingReason.for_running(%{
               tracker_state: "rework",
               pause_reason: nil,
               work_state: :working,
               stale_for_seconds: 5,
               stall_timeout_seconds: 3600
             }) == :waiting_for_human
    end

    test "tracker state merging maps to waiting_for_supervisor" do
      assert WaitingReason.for_running(%{
               tracker_state: "merging",
               pause_reason: nil,
               work_state: :working,
               stale_for_seconds: 5,
               stall_timeout_seconds: 3600
             }) == :waiting_for_supervisor
    end

    test "an agent-requested pause with no explanatory tracker state waits for a human" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: :agent_pause_request,
               work_state: :paused,
               stale_for_seconds: 5,
               stall_timeout_seconds: 3600
             }) == :waiting_for_human
    end

    test "a GitHub budget hold is transient rather than human-required" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: :github_budget_hold,
               work_state: :paused,
               stale_for_seconds: 5,
               stall_timeout_seconds: 3600
             }) == :paused_transient
    end

    test "input_required also waits for a human" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: :input_required,
               work_state: :paused,
               stale_for_seconds: 5,
               stall_timeout_seconds: 3600
             }) == :waiting_for_human
    end

    test "an unexplained pause falls back to the generic paused reason, never blocked" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: :worker_pause_unknown,
               work_state: :paused,
               stale_for_seconds: 5,
               stall_timeout_seconds: 3600
             }) == :paused
    end

    test "a sleeping agent is paused" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: nil,
               work_state: :sleeping,
               stale_for_seconds: 5,
               stall_timeout_seconds: 3600
             }) == :paused
    end

    test "a sleeping agent past the stall timeout is unresponsive, matching the watchdog's own exemption set" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: nil,
               work_state: :sleeping,
               stale_for_seconds: 3601,
               stall_timeout_seconds: 3600
             }) == :unresponsive
    end
  end

  describe "for_retry/0" do
    test "every retry-queue row is backing off" do
      assert WaitingReason.for_retry() == :backing_off
    end
  end

  describe "for_idle/3" do
    test "an unresolved dependency wins over tracker state" do
      assert WaitingReason.for_idle("ci-wait", true, 0) == :waiting_for_dependency
    end

    test "an open decision wins over dependency and tracker state" do
      assert WaitingReason.for_idle("ci-wait", true, 1) == :waiting_for_human
    end

    test "falls back to tracker-state classification" do
      assert WaitingReason.for_idle("ci-wait", false, 0) == :waiting_for_ci
      assert WaitingReason.for_idle("human-review", false, 0) == :waiting_for_review
      assert WaitingReason.for_idle("rework", false, 0) == :waiting_for_human
      assert WaitingReason.for_idle("merging", false, 0) == :waiting_for_supervisor
      assert WaitingReason.for_idle("todo", false, 0) == :active
      assert WaitingReason.for_idle(nil, false, 0) == :active
    end

    test "an active capacity hold makes a dispatchable row back off instead of reading active" do
      assert WaitingReason.for_idle("todo", false, 0, capacity_hold_active?: true) == :backing_off
      assert WaitingReason.for_idle(nil, false, 0, capacity_hold_active?: true) == :backing_off
    end

    test "capacity backoff never masks an open decision or a dependency" do
      assert WaitingReason.for_idle("todo", true, 0, capacity_hold_active?: true) == :waiting_for_dependency
      assert WaitingReason.for_idle("todo", false, 1, capacity_hold_active?: true) == :waiting_for_human
    end

    test "a capacity hold does not reclassify non-dispatchable tracker states" do
      assert WaitingReason.for_idle("ci-wait", false, 0, capacity_hold_active?: true) == :waiting_for_ci
      assert WaitingReason.for_idle("human-review", false, 0, capacity_hold_active?: true) == :waiting_for_review
    end
  end

  describe "for_idle/4" do
    test "a lifetime-latched idle ticket classifies as latched (not resume-clearable)" do
      assert WaitingReason.for_idle("error", false, 0, latched_lifetime: true) == :latched_lifetime
    end

    test "an operator label pause classifies as paused_operator" do
      assert WaitingReason.for_idle("rework", false, 0, tracker_paused: true) == :paused_operator
    end

    test "a pending transient auto-resume classifies as paused_transient" do
      assert WaitingReason.for_idle("error", false, 0, auto_resume_retry_in_ms: 120_000) == :paused_transient
    end

    test "a tracker preflight hold names an otherwise dispatchable row" do
      assert WaitingReason.for_idle("todo", false, 0, dispatch_hold_reason: :tracker_preflight) ==
               :tracker_unavailable

      assert WaitingReason.for_idle("ci-wait", false, 0, dispatch_hold_reason: :tracker_preflight) ==
               :waiting_for_ci
    end

    test "the latch wins over an operator pause and a pending transient resume" do
      assert WaitingReason.for_idle("error", false, 0,
               latched_lifetime: true,
               tracker_paused: true,
               auto_resume_retry_in_ms: 120_000
             ) == :latched_lifetime
    end

    test "an operator pause wins over a pending transient resume" do
      assert WaitingReason.for_idle("error", false, 0,
               tracker_paused: true,
               auto_resume_retry_in_ms: 120_000
             ) == :paused_operator
    end

    test "no #1453 evidence falls back to the base idle classification" do
      assert WaitingReason.for_idle("rework", false, 0, []) == :waiting_for_human
      assert WaitingReason.for_idle("todo", false, 0, latched_lifetime: false) == :active
    end

    test "a #1453 cause wins over a capacity hold, which only masks the active fallback" do
      assert WaitingReason.for_idle("todo", false, 0,
               capacity_hold_active?: true,
               latched_lifetime: true
             ) == :latched_lifetime

      assert WaitingReason.for_idle("todo", false, 0,
               capacity_hold_active?: true,
               auto_resume_retry_in_ms: 120_000
             ) == :paused_transient
    end
  end

  describe "render/1" do
    test "renders the released-claim classifier (#1475)" do
      assert WaitingReason.render(:claim_released) == "claim_released"
    end
  end
end
