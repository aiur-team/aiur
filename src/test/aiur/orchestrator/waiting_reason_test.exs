defmodule Aiur.Orchestrator.WaitingReasonTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.WaitingReason

  describe "for_running/1" do
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

    test "a deliberately paused agent is never classified as unresponsive" do
      assert WaitingReason.for_running(%{
               tracker_state: "in-progress",
               pause_reason: :operator_pause,
               work_state: :paused,
               stale_for_seconds: 999_999,
               stall_timeout_seconds: 3600
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
  end

  describe "for_retry/0" do
    test "every retry-queue row is backing off" do
      assert WaitingReason.for_retry() == :backing_off
    end
  end

  describe "for_idle/2" do
    test "an unresolved dependency wins over tracker state" do
      assert WaitingReason.for_idle("ci-wait", true) == :waiting_for_dependency
    end

    test "falls back to tracker-state classification" do
      assert WaitingReason.for_idle("ci-wait", false) == :waiting_for_ci
      assert WaitingReason.for_idle("human-review", false) == :waiting_for_review
      assert WaitingReason.for_idle("rework", false) == :waiting_for_human
      assert WaitingReason.for_idle("merging", false) == :waiting_for_supervisor
      assert WaitingReason.for_idle("todo", false) == :active
      assert WaitingReason.for_idle(nil, false) == :active
    end
  end
end
