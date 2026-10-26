defmodule Aiur.Orchestrator.HostedAuthFailureTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Issue
  alias Aiur.Orchestrator.{RetryEngine, State}

  @failure {:unsafe_hosted_authentication, "codex", :subscription}

  setup do
    Publisher.set_tracked_fn(fn _identifier -> true end)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _identifier -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    :ok
  end

  test "the runner preserves a hosted-auth refusal as a terminal policy exit" do
    issue = %Issue{id: "issue-hosted-auth", identifier: "HOSTED-1", title: "hosted auth", selected_backend: "codex"}

    assert catch_exit(AgentRunner.handle_run_error(issue, {:turn_unretryable, @failure})) ==
             {:terminal_policy_failure, @failure}
  end

  test "a terminal hosted-auth exit writes error evidence without scheduling a retry" do
    issue_id = "issue-hosted-auth"
    identifier = "HOSTED-1"
    ref = make_ref()
    test_pid = self()
    :ok = Exchange.subscribe("ticket.#{identifier}.agent.attention.hosted-authentication-refused")

    writer = fn written_identifier, state_name, opts ->
      send(test_pid, {:state_write, written_identifier, state_name, opts})
      :ok
    end

    state = %State{
      running: %{
        issue_id => %{
          ref: ref,
          identifier: identifier,
          started_at: DateTime.utc_now(),
          retry_attempt: 2,
          terminal_policy_state_writer: writer
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{issue_id => %{attempt: 2}}
    }

    assert {:noreply, stopped} =
             RetryEngine.handle_agent_down(state, ref, {:terminal_policy_failure, @failure})

    refute Map.has_key?(stopped.running, issue_id)
    refute MapSet.member?(stopped.claimed, issue_id)
    refute Map.has_key?(stopped.retry_attempts, issue_id)
    assert stopped.released_claims[issue_id].cause == :terminal_policy_failure
    assert stopped.released_claims[issue_id].details == %{provider: "codex", auth_class: :subscription}
    assert stopped.observed_error_alert_causes[issue_id] == :terminal_policy_failure

    assert_received {:state_write, ^identifier, "error", []}

    assert_receive {:event, %{topic: "ticket.HOSTED-1.agent.attention.hosted-authentication-refused"} = event}, 500
    assert event["message"] =~ "codex authentication class subscription"
    refute event["message"] =~ "retry attempts"
  end
end
