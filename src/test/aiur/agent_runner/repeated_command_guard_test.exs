defmodule Aiur.AgentRunner.RepeatedCommandGuardTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentRunner.MessageHandler, Issue}
  alias Aiur.AgentRunner.RepeatedCommandGuard
  alias Aiur.AgentRunner.RepeatedCommandStop

  defmodule RestoreQueue do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, nil)
    def init(state), do: {:ok, state}

    def handle_call({:restore_delivered_queue_items, _identifier}, _from, state),
      do: {:reply, :ok, state}
  end

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

  test "message handler steers on fifth Codex read completion and stops on sixth" do
    RepeatedCommandGuard.start_turn(repeat_threshold: 5)
    {:ok, orchestrator} = RestoreQueue.start_link()
    sent = self()
    handler = MessageHandler.build(nil, %Issue{}, nil, nil, "codex", nil, repeated_command_steerer: &send(sent, {:steer, &1}))
    issue = %Issue{id: "issue-repeat", identifier: "AIUR-6016"}

    turn_context = %{
      issue: issue,
      workspace: "/workspace",
      worker_host: nil,
      codex_update_recipient: self(),
      orchestrator: orchestrator,
      pause_marker_writer: fn identifier, label ->
        send(self(), {:pause_marker, identifier, label})
        :ok
      end,
      attention_emitter: fn topic, opts ->
        send(self(), {:attention, topic, opts})
        :ok
      end
    }

    result =
      try do
        for _ <- 1..6, do: handler.(codex_command("tail -40 build.log", "failed build"))
        flunk("the sixth identical command must stop the turn")
      catch
        :throw, {:repeated_identical_command, command, count} ->
          RepeatedCommandStop.stop_on_repeated_command(turn_context, command, count)
      end

    assert_receive {:steer, body}, 100
    assert body =~ "5 consecutive calls"
    assert body =~ "act on it or stop and hand off"
    assert {:completed, %Issue{paused: true}} = result
    assert_receive {:pause_marker, "AIUR-6016", label}, 100
    assert String.ends_with?(label, ":paused")
    assert_receive {:attention, "ticket.AIUR-6016.agent.attention.repeated-identical-command", opts}, 100
    assert opts[:needs_attention]
    assert opts[:message] =~ "tail -40 build.log"
    assert opts[:message] =~ "6 times"
    assert_receive {:worker_control_state, "issue-repeat", :paused, %{kind: :repeated_identical_command}}, 100
  end

  test "Claude Bash result is paired with its tool call and intervening sleep resets the streak" do
    RepeatedCommandGuard.start_turn(repeat_threshold: 2)
    handler = MessageHandler.build(nil, %Issue{}, nil, nil, "claude")

    claude_command(handler, "item-1", "tool-1", "tail -40 build.log", "same")
    claude_command(handler, "item-2", "tool-2", "sleep 1", "slept")
    claude_command(handler, "item-3", "tool-3", "tail -40 build.log", "same")
    claude_command(handler, "item-4", "tool-4", "tail -40 build.log", "same")

    assert catch_throw(claude_command(handler, "item-5", "tool-5", "tail -40 build.log", "same")) ==
             {:repeated_identical_command, "tail -40 build.log", 3}
  end

  test "OpenAI-compatible exec_command results count shell commands and steer through message handler" do
    RepeatedCommandGuard.start_turn(repeat_threshold: 5)
    sent = self()
    handler = MessageHandler.build(nil, %Issue{}, nil, nil, "kimi", nil, repeated_command_steerer: &send(sent, {:steer, &1}))

    for _ <- 1..5, do: openai_command(handler, "tail -40 build.log", "same")
    assert_receive {:steer, body}, 100
    assert body =~ "5 consecutive calls"

    assert catch_throw(openai_command(handler, "tail -40 build.log", "same")) ==
             {:repeated_identical_command, "tail -40 build.log", 6}
  end

  test "varied output and compound shell commands reset the read streak" do
    RepeatedCommandGuard.start_turn(repeat_threshold: 2)
    handler = MessageHandler.build(nil, %Issue{}, nil, nil, "codex")

    handler.(codex_command("tail -40 build.log", "same"))
    handler.(codex_command("tail -40 build.log", "changed"))
    handler.(codex_command("tail -40 other.log", "same"))
    handler.(codex_command("tail -40 build.log", "same"))
    handler.(codex_command("tail -40 build.log && sleep 1", "same"))
    handler.(codex_command("tail -40 build.log", "same"))
    assert handler.(codex_command("tail -40 build.log", "same")) == :ok
  end

  test "configured command cap counts completed shell commands on every backend" do
    for backend <- ["codex", "claude", "kimi"] do
      RepeatedCommandGuard.start_turn(command_cap: 1)
      handler = MessageHandler.build(nil, %Issue{}, nil, nil, backend)
      handler.(%{event: :tool_call, payload: %{id: "dynamic-1", name: "unrelated_dynamic_tool", arguments: %{}}})
      command = "sleep 1"

      assert catch_throw(run_backend_command(handler, backend, command, "done")) ==
               {:turn_cap, :commands, 1}
    end
  end

  test "optional input-token cap remains supported" do
    RepeatedCommandGuard.start_turn(input_token_cap: 100)

    RepeatedCommandGuard.start_turn(input_token_cap: 100)
    assert RepeatedCommandGuard.observe_message(%{accounting_usage: %{input_tokens: 80}}) == :ok

    assert catch_throw(RepeatedCommandGuard.observe_message(%{accounting_usage: %{input_tokens: 101}})) ==
             {:turn_cap, :input_tokens, 101}

    RepeatedCommandGuard.start_turn(input_token_cap: 100)
    assert RepeatedCommandGuard.observe_message(%{usage_epoch: {"session", 1}, accounting_usage: %{input_tokens: 10}}) == :ok
    assert RepeatedCommandGuard.observe_message(%{usage_epoch: {"session", 1}, accounting_usage: %{input_tokens: 80}}) == :ok
    assert catch_throw(RepeatedCommandGuard.observe_message(%{usage_epoch: {"session", 1}, accounting_usage: %{input_tokens: 111}})) == {:turn_cap, :input_tokens, 101}
  end

  defp codex_command(command, output) do
    %{
      event: :notification,
      payload: %{
        "method" => "item/completed",
        "params" => %{
          "item" => %{
            "type" => "commandExecution",
            "status" => "completed",
            "command" => "/usr/bin/zsh -lc '#{command}'",
            "commandActions" => [%{"command" => command}],
            "aggregatedOutput" => output
          }
        }
      }
    }
  end

  defp claude_command(handler, item_id, tool_id, command, output) do
    handler.(%{
      event: :notification,
      payload: %{
        "method" => "item/created",
        "params" => %{
          "item" => %{
            "id" => item_id,
            "tool_use_id" => tool_id,
            "type" => "tool_call",
            "name" => "Bash",
            "input" => %{"command" => command}
          }
        }
      }
    })

    handler.(%{
      event: :notification,
      payload: %{
        "method" => "item/created",
        "params" => %{
          "item" => %{
            "id" => "result-#{item_id}",
            "type" => "tool_result",
            "tool_use_id" => tool_id,
            "content" => output
          }
        }
      }
    })
  end

  defp openai_command(handler, command, output) do
    id = make_ref() |> inspect()
    handler.(%{event: :tool_call, payload: %{id: id, name: "exec_command", arguments: %{"command" => command}}})
    handler.(%{event: :tool_result, payload: %{id: id, name: "exec_command", output: output}})
  end

  defp run_backend_command(handler, "codex", command, output), do: handler.(codex_command(command, output))

  defp run_backend_command(handler, "claude", command, output),
    do: claude_command(handler, "cap-item", "cap-tool", command, output)

  defp run_backend_command(handler, _backend, command, output), do: openai_command(handler, command, output)
end
