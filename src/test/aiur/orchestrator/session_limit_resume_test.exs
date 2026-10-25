defmodule Aiur.Orchestrator.SessionLimitResumeTest do
  use Aiur.TestSupport

  alias Aiur.Alerts
  alias Aiur.Events.Exchange
  alias Aiur.Issue
  alias Aiur.Orchestrator.{ControlLifecycle, PauseResume, RateLimitFallback, State}
  alias Aiur.TrackerIdentity

  test "pending resumes do not consume transition allowance and resolve stalled alerts after delayed acknowledgments" do
    :ok = Exchange.subscribe("ticket.1.agent.stalled.resolved")
    :ok = Exchange.subscribe("ticket.2.agent.stalled.resolved")

    on_exit(fn ->
      Exchange.unsubscribe("ticket.1.agent.stalled.resolved")
      Exchange.unsubscribe("ticket.2.agent.stalled.resolved")
    end)

    :ok = Alerts.emit_custom("ticket.1.agent.stalled", "worker stalled", issue: "1", needs_attention: true)
    running = Map.new(["1", "2"], &{&1, paused_entry(&1)})
    state = %State{running: running, max_concurrent_agents: 4}
    opts = [primary_backend: "claude", fallback_backend: nil, current_backend: "claude", state: %{"backends" => %{}}]

    assert RateLimitFallback.decide(running["1"], running["1"].issue, opts) == :resume
    assert PauseResume.resume_paused_issue_preflight(state, running["1"]) == :ok
    assert TrackerIdentity.joinable?(running["1"].issue.tracker_identity)
    first = RateLimitFallback.reconcile(state, opts)

    request_ids =
      for _ <- 1..2, into: MapSet.new() do
        assert_receive {:resume_agent, request_id, 1}, 1_000
        request_id
      end

    assert MapSet.size(request_ids) == 2
    refute_received {:resume_agent, _, _}
    assert first.running["1"].control.status == :paused
    assert first.running["2"].control.status == :paused
    assert ControlLifecycle.current_pending(first.control_lifecycle, "1").request_id in request_ids
    assert ControlLifecycle.current_pending(first.control_lifecycle, "2").request_id in request_ids

    polled = Enum.reduce(1..4, first, fn _, acc -> RateLimitFallback.reconcile(acc, opts) end)
    refute_received {:resume_agent, _, _}
    assert ControlLifecycle.current_pending(polled.control_lifecycle, "1")
    assert ControlLifecycle.current_pending(polled.control_lifecycle, "2")

    final =
      Enum.reduce(["1", "2"], polled, fn id, acc ->
        request_id = ControlLifecycle.current_pending(acc.control_lifecycle, id).request_id

        assert {:noreply, resumed} =
                 PauseResume.handle_worker_control_state(acc, id, :working, %{request_id: request_id, generation: 1})

        assert resumed.running[id].control.status == :working
        assert ControlLifecycle.get(resumed.control_lifecycle, request_id).status == :applied
        resumed
      end)

    assert RateLimitFallback.reconcile(final, opts) == final
    refute_received {:resume_agent, _, _}
    assert_received {:event, %{topic: "ticket.1.agent.stalled.resolved"}}
    refute_received {:event, %{topic: "ticket.2.agent.stalled.resolved"}}
  end

  defp paused_entry(id) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: id,
      issue: %Issue{
        id: id,
        identifier: id,
        title: "Paused ticket",
        state: "In Progress",
        selected_backend: "claude",
        tracker_identity: %TrackerIdentity{version: 1, status: :joinable, kind: :github, owner: "owner", repository: "repo", provider_id: "I_#{id}", identifier: id, reason: nil}
      },
      started_at: DateTime.utc_now(),
      paused_reason: :usage_limit_exhausted,
      usage_limit_reset_at: "2026-01-01T00:00:00Z",
      control: %{status: :paused, can_interrupt: true, generation: 1, version: 1, application_confirmation: :confirmed}
    }
  end
end
