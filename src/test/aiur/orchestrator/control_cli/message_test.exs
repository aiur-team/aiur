Code.require_file("fixture.exs", __DIR__)

defmodule Aiur.Orchestrator.ControlCLI.MessageTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Orchestrator.ControlCLI.Message, as: AgentControlCLI
  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    TestFixture.setup(context)
  end

  test "message status timeout exits 124" do
    Application.put_env(:aiur, :agent_control_cli_status_fun, fn -> :timeout end)
    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_status_fun) end)

    output = capture_io(fn -> AgentControlCLI.message("44", "hello") end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: timed out while reading agent status"
    assert output =~ "__AIUR_CONTROL_EXIT__:124"
  end

  test "message reports an unclaimed message as queued without claiming delivery", %{orchestrator: pid} do
    parent = self()

    Application.put_env(:aiur, :agent_control_cli_message_fun, fn identifier, text ->
      send(parent, {:send_requested, identifier, text})
      {:ok, 7}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)
    stub_message_delivery_status({:ok, :pending})

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    output =
      with_message_confirm_timeout(150, fn ->
        capture_io(fn -> AgentControlCLI.message("44", "ship it") end)
      end)

    assert output =~ "aiur: queued message for #44 (request 7); delivery is unconfirmed"
    refute output =~ "aiur: messaged"
    refute output =~ "delivered"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    # Enqueued through the canonical identifier, not the bare issue number.
    assert_receive {:send_requested, "repo#44", "ship it"}, 500
  end

  test "message reports delivery only once the agent has claimed the message", %{orchestrator: pid} do
    parent = self()

    Application.put_env(:aiur, :agent_control_cli_message_fun, fn _identifier, _text -> {:ok, 7} end)
    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)

    # Pending on the first read, claimed on the second: the poll must observe
    # the transition rather than settle on its first answer.
    Application.put_env(:aiur, :agent_control_cli_message_status_fun, fn request_id, _timeout ->
      send(parent, {:status_read, request_id})

      if Process.get(:message_status_read) do
        {:ok, :delivered}
      else
        Process.put(:message_status_read, true)
        {:ok, :pending}
      end
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_status_fun) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    output =
      with_message_confirm_timeout(1_000, fn ->
        capture_io(fn -> AgentControlCLI.message("44", "ship it") end)
      end)

    assert output =~ "aiur: delivered message to #44 (request 7)"
    refute output =~ "queued message"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert_receive {:status_read, 7}, 500
  end

  test "message reports a settled non-delivery distinctly from an unconfirmed one", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_message_fun, fn _identifier, _text -> {:ok, 7} end)
    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)
    stub_message_delivery_status({:ok, :failed})

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    output =
      with_message_confirm_timeout(1_000, fn ->
        capture_io(fn -> AgentControlCLI.message("44", "ship it") end)
      end)

    assert output =~ "aiur: queued message for #44 (request 7); not delivered (failed)"
    refute output =~ "delivery is unconfirmed"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  # An unreadable status is not evidence of delivery. The enqueue still
  # succeeded, so this reports as queued rather than as a failure.
  test "message reports queued when the delivery status cannot be read", %{orchestrator: pid} do
    Application.put_env(:aiur, :agent_control_cli_message_fun, fn _identifier, _text -> {:ok, 7} end)
    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)
    stub_message_delivery_status({:error, :unavailable})

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    output =
      with_message_confirm_timeout(150, fn ->
        capture_io(fn -> AgentControlCLI.message("44", "ship it") end)
      end)

    assert output =~ "aiur: queued message for #44 (request 7); delivery is unconfirmed"
    refute output =~ "delivered"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  # #2717. The daemon may still queue a message after the send timed out, so a
  # timeout is an unknown outcome. It must not read as a failed send, and it
  # must name the one retry that is safe: the same command with this send's id.
  test "message reports a timed-out send as outcome unknown with the exact retry command", %{orchestrator: pid} do
    parent = self()

    Application.put_env(:aiur, :agent_control_cli_message_fun, fn _identifier, _text, opts ->
      send(parent, {:message_id, Keyword.fetch!(opts, :message_id)})
      {:error, {:outcome_unknown, %{message_id: Keyword.fetch!(opts, :message_id), item_id: nil}}}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.message("44", "don't stop") end)
        assert_receive {:message_id, "cli-" <> _ = message_id}, 1000

        assert output =~ "aiur: outcome unknown for message to #44"
        assert output =~ "(message id #{message_id})"
        assert output =~ ~s(run: aiur message 44 --message-id #{message_id} 'don'\\''t stop')
        refute output =~ "will not queue a duplicate"
        refute output =~ "failed to message"
        refute output =~ "__AIUR_CONTROL_ERROR__"
        assert output =~ "__AIUR_CONTROL_EXIT__:124"
      end)

    refute stderr =~ "failed"
  end

  test "message sends a given --message-id and a new id for each plain send", %{orchestrator: pid} do
    parent = self()

    Application.put_env(:aiur, :agent_control_cli_message_fun, fn _identifier, text, opts ->
      send(parent, {:sent, text, Keyword.fetch!(opts, :message_id)})
      {:ok, 7}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)
    stub_message_delivery_status({:ok, :delivered})

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    capture_io(fn ->
      AgentControlCLI.message("44", "continue", "retry-1")
      AgentControlCLI.message("44", "continue")
      AgentControlCLI.message("44", "continue")
    end)

    assert_receive {:sent, "continue", "retry-1"}, 1000
    assert_receive {:sent, "continue", "cli-" <> _ = second}, 1000
    assert_receive {:sent, "continue", "cli-" <> _ = third}, 1000
    refute second == third
  end

  test "message to a non-running issue fails with a clear error" do
    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> AgentControlCLI.message("45", "hello") end)

        assert output =~ "__AIUR_CONTROL_EXIT__:1"
      end)

    assert stderr =~ "aiur: failed to message #45 (no running agent)"
  end

  test "message surfaces delivery errors with a non-zero exit", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)

    for {reason, expected} <- [
          {:empty_message, "message is empty"},
          {:message_too_long, "message is too long"},
          {:invalid_message, "invalid message"},
          {:agent_finished, "agent is not accepting messages (agent finished)"}
        ] do
      Application.put_env(:aiur, :agent_control_cli_message_fun, fn _identifier, _text ->
        {:error, reason}
      end)

      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.message("44", "anything") end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "aiur: failed to message #44 (#{expected})"
    end
  end

  test "message reports a clear error when the orchestrator is unavailable", %{orchestrator: pid} do
    Process.unregister(Orchestrator)

    try do
      stderr =
        capture_io(:stderr, fn ->
          output = capture_io(fn -> AgentControlCLI.message("44", "hi") end)

          assert output =~ "__AIUR_CONTROL_EXIT__:1"
        end)

      assert stderr =~ "aiur: orchestrator is not running"
    after
      Process.register(pid, Orchestrator)
    end
  end

  test "message reports a marker when delivery raises instead of failing silently", %{orchestrator: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}}
    end)

    Application.put_env(:aiur, :agent_control_cli_message_fun, fn _identifier, _text ->
      raise "delivery process exited"
    end)

    on_exit(fn -> Application.delete_env(:aiur, :agent_control_cli_message_fun) end)

    output = capture_io(fn -> AgentControlCLI.message("44", "hello") end)

    assert output =~ "__AIUR_CONTROL_ERROR__:aiur: message query failed"
    assert output =~ "delivery process exited"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end
end
