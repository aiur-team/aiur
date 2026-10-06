defmodule Aiur.Codex.DynamicTool.TicketStateTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool
  alias Aiur.Codex.DynamicTool.TicketState

  describe "execute/3 — aiur_set_ticket_state" do
    test "declares the target state without naming any label to remove (#2805)" do
      # The whole point of the tool: the agent says where it is going and never
      # names the label to remove, because any label it names is a guess about
      # the past. `gh issue edit --remove-label agent:ci-wait` was that guess,
      # and when the daemon's CI-pass handoff had already replaced `ci-wait` the
      # removal was a silent no-op that left two state labels behind.
      response =
        TicketState.execute(
          "aiur_set_ticket_state",
          %{"state" => "human-review"},
          ticket_state_setter: fn state -> {:ok, %{state: state}} end
        )

      assert response["success"] == true
      decoded = Jason.decode!(response["output"])
      assert decoded["ok"] == true
      assert decoded["state"] == "human-review"
      assert decoded["result"]["state"] == "human-review"
    end

    test "accepts the prefixed and mixed-case label shape agents actually type" do
      for given <- ["agent:human-review", "  Agent:Human-Review  ", "HUMAN-REVIEW"] do
        response =
          TicketState.execute(
            "aiur_set_ticket_state",
            %{"state" => given},
            ticket_state_setter: fn state -> {:ok, state} end
          )

        assert response["success"] == true
        assert Jason.decode!(response["output"])["state"] == "human-review"
      end
    end

    test "refuses a state an agent must not claim for itself" do
      # `todo` is dispatch's pre-work state and `merging`/`cancelled` are
      # Executor dispositions; writing either from an agent turn would reverse a
      # decision the agent does not own.
      for refused <- ["todo", "merging", "cancelled", "not-a-state"] do
        response =
          TicketState.execute(
            "aiur_set_ticket_state",
            %{"state" => refused},
            ticket_state_setter: fn _state -> flunk("must not write #{refused}") end
          )

        assert response["success"] == false
        assert Jason.decode!(response["output"])["error"]["state"] == refused
      end
    end

    test "missing or non-string state is refused before any write" do
      assert %{"success" => false} =
               response =
               TicketState.execute("aiur_set_ticket_state", %{}, ticket_state_setter: fn _ -> flunk("no write") end)

      assert Jason.decode!(response["output"])["error"]["message"] =~ "required"

      assert %{"success" => false} =
               bad =
               TicketState.execute("aiur_set_ticket_state", %{"state" => 7}, ticket_state_setter: fn _ -> flunk("no write") end)

      assert Jason.decode!(bad["output"])["error"]["message"] =~ "string"
    end

    test "a tracker write failure surfaces as a tool failure" do
      response =
        TicketState.execute(
          "aiur_set_ticket_state",
          %{"state" => "ci-wait"},
          ticket_state_setter: fn _state -> {:error, {:stale_issue_state, "ci-wait", "rework"}} end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] =~ "stale_issue_state"
    end

    test "without a bound writer the tool reports itself unavailable" do
      response = TicketState.execute("aiur_set_ticket_state", %{"state" => "ci-wait"}, [])

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "unavailable"
    end
  end

  describe "registration" do
    test "the tool is dispatchable through DynamicTool and advertises its schema" do
      spec = Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "aiur_set_ticket_state"))

      assert spec["inputSchema"]["required"] == ["state"]
      assert spec["description"] =~ "ONLY"

      response =
        DynamicTool.execute("aiur_set_ticket_state", %{"state" => "in-progress"}, ticket_state_setter: fn state -> {:ok, state} end)

      assert response["success"] == true
      assert Jason.decode!(response["output"])["state"] == "in-progress"
    end
  end
end
