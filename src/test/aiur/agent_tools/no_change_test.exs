defmodule Aiur.AgentTools.NoChangeTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentTools.{Dispatch, NoChange}

  @commit String.duplicate("a", 40)

  test "refuses absent or incomplete evidence before requesting a handoff" do
    for args <- [%{}, %{"commit" => @commit, "command" => "mix test"}, %{"commit" => "abc", "command" => "mix test", "output" => "1 test, 0 failures"}] do
      response = NoChange.execute("aiur_finish_no_change", args, no_change_finisher: fn _, _ -> flunk("must not hand off") end)

      assert response["success"] == false
    end
  end

  test "records complete evidence through the registered worker tool" do
    parent = self()

    response =
      Dispatch.execute(
        "aiur_finish_no_change",
        %{"commit" => @commit, "command" => "mix test test/fix_test.exs", "output" => "1 test, 0 failures"},
        no_change_finisher: fn evidence, _opts ->
          send(parent, {:evidence, evidence})
          {:ok, %{state: "done", evidence_recorded: true, no_op_limit_exempt: true}}
        end
      )

    assert_received {:evidence, %{"commit" => @commit, "command" => "mix test test/fix_test.exs", "output" => "1 test, 0 failures"}}
    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"state" => "done", "evidence_recorded" => true, "no_op_limit_exempt" => true}
  end
end
