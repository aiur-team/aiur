Code.require_file("fixture.exs", __DIR__)

defmodule Aiur.Orchestrator.ControlCLI.KeyedMessageTest do
  # A reconciler that crashes after `aiur message --message-id K` and runs it
  # again must get the first receipt back, even after the queue item is gone
  # or the daemon restarted, and must never queue a second copy.
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.ControlCall.ReplayStore
  alias Aiur.Orchestrator.ControlCLI.Message, as: AgentControlCLI
  alias Aiur.Orchestrator.ControlCLI.TestFixture

  import TestFixture, except: [setup: 1]

  setup context do
    fixture = TestFixture.setup(context)
    root = Path.join(System.tmp_dir!(), "keyed-message-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :control_replay_state_dir)
    Application.put_env(:aiur, :control_replay_state_dir, root)
    ReplayStore.reload()
    stub_message_delivery_status({:ok, :pending})

    parent = self()

    Application.put_env(:aiur, :agent_control_cli_message_fun, fn identifier, text, opts ->
      send(parent, {:sent, identifier, text, opts[:message_id]})
      Process.get(:send_result, {:ok, 7})
    end)

    on_exit(fn ->
      Application.delete_env(:aiur, :agent_control_cli_message_fun)
      if previous, do: Application.put_env(:aiur, :control_replay_state_dir, previous), else: Application.delete_env(:aiur, :control_replay_state_dir)
      ReplayStore.reload()
      Aiur.TestCleanup.rm_rf!(root)
    end)

    fixture
  end

  defp message(text, key), do: with_message_confirm_timeout(50, fn -> capture_io(fn -> AgentControlCLI.message("44", text, key) end) end)

  test "a repeated key returns the first receipt across a restart and never sends again" do
    first = message("Use option B", "recon-768-r2")
    assert first =~ "(request 7)"
    assert first =~ "__AIUR_CONTROL_EXIT__:0"
    assert_receive {:sent, _identifier, "Use option B", "recon-768-r2"}

    ReplayStore.reload()

    again = message("Use option B", "recon-768-r2")
    assert again =~ "aiur: message recon-768-r2 already sent to 44 (request 7); nothing queued again"
    assert again =~ "__AIUR_CONTROL_EXIT__:0"
    refute_receive {:sent, _identifier, _text, _key}, 50

    clash = message("Use option C", "recon-768-r2")
    assert clash =~ "this key was already used with different arguments"
    assert clash =~ "__AIUR_CONTROL_EXIT__:65"
    refute_receive {:sent, _identifier, _text, _key}, 50
  end

  test "a keyed send that queued nothing may be retried under the same key" do
    Process.put(:send_result, {:error, :queue_full})
    failed = message("Retry me", "recon-768-r3")
    refute failed =~ "__AIUR_CONTROL_EXIT__:0"
    assert_receive {:sent, _identifier, "Retry me", "recon-768-r3"}

    Process.put(:send_result, {:ok, 9})
    retried = message("Retry me", "recon-768-r3")
    assert retried =~ "(request 9)"
    assert_receive {:sent, _identifier, "Retry me", "recon-768-r3"}
  end
end
