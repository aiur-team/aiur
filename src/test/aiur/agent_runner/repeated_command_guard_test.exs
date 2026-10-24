defmodule Aiur.AgentRunner.RepeatedCommandGuardTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.RepeatedCommandGuard
  alias Aiur.AgentRunner.ToolExecutor

  test "counts identical command output consecutively and formats steering after the threshold" do
    command = "tail -40 gate-9.log"
    output = "make: *** Error 2"

    {state, :varied} = RepeatedCommandGuard.observe(nil, command, output)
    {state, :repeat} = RepeatedCommandGuard.observe(state, command, output)
    {state, :repeat} = RepeatedCommandGuard.observe(state, command, output)

    assert state.count == 3

    assert RepeatedCommandGuard.steering_message(command, state.count) ==
             "The output of `\"tail -40 gate-9.log\"` has not changed for 3 consecutive calls; act on it or stop and hand off."
  end

  test "a changed command or output starts a new streak" do
    {first, :varied} = RepeatedCommandGuard.observe(nil, "cat a", "same")
    {changed_command, :varied} = RepeatedCommandGuard.observe(first, "cat b", "same")
    {changed_output, :varied} = RepeatedCommandGuard.observe(changed_command, "cat b", "new")

    assert changed_command.count == 1
    assert changed_output.count == 1
  end

  test "steers on the fifth identical read and throws on the next identical read" do
    RepeatedCommandGuard.start_turn(repeat_threshold: 5)
    args = %{"command" => "tail -40 gate-9.log"}

    for _ <- 1..4 do
      assert %{"output" => "unchanged"} =
               ToolExecutor.execute(fn _tool, _args -> %{"output" => "unchanged"} end, "exec_command", args, make_ref())
    end

    assert %{"output" => output} =
             ToolExecutor.execute(fn _tool, _args -> %{"output" => "unchanged"} end, "exec_command", args, make_ref())

    assert output =~ "act on it or stop and hand off"

    assert catch_throw(ToolExecutor.execute(fn _tool, _args -> %{"output" => "unchanged"} end, "exec_command", args, make_ref())) ==
             {:repeated_identical_command, "tail -40 gate-9.log", 6}
  end

  test "varied commands and mutating commands do not trigger the guard" do
    RepeatedCommandGuard.start_turn(repeat_threshold: 2)

    run = fn tool, args, output ->
      ToolExecutor.execute(fn _tool, _args -> %{"output" => output} end, tool, args, make_ref())
    end

    assert %{"output" => "a"} = run.("exec_command", %{"command" => "cat a"}, "a")
    assert %{"output" => "b"} = run.("exec_command", %{"command" => "cat b"}, "b")
    assert %{"output" => "x"} = run.("exec_command", %{"command" => "rm -rf x"}, "x")
  end

  test "optional command and input-token caps are off unless configured" do
    RepeatedCommandGuard.start_turn(command_cap: 1, input_token_cap: 100)
    assert catch_throw(RepeatedCommandGuard.observe_tool("exec_command", %{"command" => "tail -40 file"}, %{"output" => "line"})) == {:turn_cap, :commands, 1}

    RepeatedCommandGuard.start_turn(input_token_cap: 100)
    assert RepeatedCommandGuard.observe_message(%{accounting_usage: %{input_tokens: 80}}) == :ok

    assert catch_throw(RepeatedCommandGuard.observe_message(%{accounting_usage: %{input_tokens: 101}})) ==
             {:turn_cap, :input_tokens, 101}

    RepeatedCommandGuard.start_turn(input_token_cap: 100)
    assert RepeatedCommandGuard.observe_message(%{usage_epoch: {"session", 1}, accounting_usage: %{input_tokens: 10}}) == :ok
    assert RepeatedCommandGuard.observe_message(%{usage_epoch: {"session", 1}, accounting_usage: %{input_tokens: 80}}) == :ok
    assert catch_throw(RepeatedCommandGuard.observe_message(%{usage_epoch: {"session", 1}, accounting_usage: %{input_tokens: 111}})) == {:turn_cap, :input_tokens, 101}
  end
end
