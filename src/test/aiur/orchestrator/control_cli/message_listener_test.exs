Code.require_file("fixture.exs", __DIR__)

defmodule Aiur.Orchestrator.ControlCLI.MessageListenerTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  alias Aiur.Orchestrator.ControlCLI.Message
  alias Aiur.Orchestrator.ControlCLI.TestFixture
  import TestFixture, except: [setup: 1]

  defmodule ReceiptTarget do
    def read_snapshot(7, _timeout), do: {:ok, %{status: :pending, delivery: Process.get(:message_delivery), provider_delivered_at: nil}}
  end

  setup context do
    result = TestFixture.setup(context)
    previous = Application.fetch_env!(:aiur, :listener_delivery_target)
    Application.put_env(:aiur, :listener_delivery_target, ReceiptTarget)
    Application.put_env(:aiur, :agent_control_cli_message_fun, fn _identifier, _text -> {:ok, 7} end)

    on_exit(fn ->
      Application.put_env(:aiur, :listener_delivery_target, previous)
      Application.delete_env(:aiur, :agent_control_cli_message_fun)
    end)

    stub_message_delivery_status({:ok, :pending})
    result
  end

  test "message names the applied mode from its receipt", %{orchestrator: pid} do
    :sys.replace_state(pid, &%{&1 | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}})

    for mode <- [:steer, :sync, :async] do
      Process.put(:message_delivery, %{listener_mode_at_claim: mode})
      output = with_message_confirm_timeout(0, fn -> capture_io(fn -> Message.message("44", "hello") end) end)
      assert output =~ "aiur: accepted under #{mode} listener mode"
      assert output =~ "__AIUR_CONTROL_EXIT__:0"
    end
  end

  # Future regression guard: legacy output already has this exact form on main.
  test "legacy receipt leaves message output unchanged", %{orchestrator: pid} do
    :sys.replace_state(pid, &%{&1 | running: %{"issue-44" => running_entry("issue-44", "repo#44", :working)}})
    Process.put(:message_delivery, %{})
    output = with_message_confirm_timeout(0, fn -> capture_io(fn -> Message.message("44", "hello") end) end)
    assert output == "aiur: queued message for #44 (request 7); delivery is unconfirmed\n__AIUR_CONTROL_EXIT__:0\n"
  end
end
