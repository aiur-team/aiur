defmodule Aiur.AgentRunner.ToolExecutorTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Issue

  describe "build/3" do
    test "returns a 2-arity closure" do
      issue = %Issue{id: "gid-te-01", identifier: "TE-01"}
      executor = ToolExecutor.build(issue, nil, nil)

      assert is_function(executor, 2)
    end

    test "delegates unknown tools to Dispatch failure response" do
      issue = %Issue{id: "gid-te-02", identifier: "TE-02"}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("not_a_real_tool", %{})

      assert response["success"] == false
    end

    test "invocation context preserves normal validation for malformed arguments" do
      issue = %Issue{id: "gid-te-invalid", identifier: "TE-invalid"}
      executor = ToolExecutor.build(issue, nil, nil)

      response = ToolExecutor.execute(executor, "emit_event", :invalid, "call-invalid")

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "expects an object"
    end
  end

  describe "set_ticket_state_for_issue via ticket_state_setter closure (#2805)" do
    test "writes the declared state for the agent's own ticket through the tracker" do
      issue = %Issue{id: "gid-te-state", identifier: "2805"}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_runner: fn _key, operation, _opts -> operation.() end,
          ticket_state_writer: fn issue_id, state ->
            send(test_pid, {:state_write, issue_id, state})
            :ok
          end
        )

      response = executor.("aiur_set_ticket_state", %{"state" => "agent:human-review"})

      # The agent names no label to remove; the write targets its own ticket and
      # the tracker's swap makes the target the sole `agent:*` state label.
      assert_receive {:state_write, "gid-te-state", "human-review"}, 1000
      assert response["success"] == true
      assert Jason.decode!(response["output"])["state"] == "human-review"
    end

    test "surfaces a tracker write failure instead of reporting a state change" do
      issue = %Issue{id: "gid-te-state-fail", identifier: "2805"}

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_runner: fn _key, operation, _opts -> operation.() end,
          ticket_state_writer: fn _issue_id, _state -> {:error, :permission_denied} end
        )

      response = executor.("aiur_set_ticket_state", %{"state" => "ci-wait"})

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "Issues:write"
    end

    test "refuses a ticket with no id or identifier rather than writing a guess" do
      issue = %Issue{id: nil, identifier: nil}
      executor = ToolExecutor.build(issue, nil, nil, %{}, ticket_state_writer: fn _id, _state -> flunk("no write") end)

      response = executor.("aiur_set_ticket_state", %{"state" => "ci-wait"})

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] =~ "no_issue_number"
    end
  end
end
