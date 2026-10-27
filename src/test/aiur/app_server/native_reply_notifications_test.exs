defmodule Aiur.AppServer.NativeReplyNotificationsTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.TurnLoop

  defmodule DoneBackend do
    def handle_method(_session, state, %{"method" => "done"}, _raw, _method), do: {:ok, state}
  end

  test "held questions inspect queue updates even when deliver-now is false" do
    port = Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [:binary, :exit_status])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    state = %{
      backend: DoneBackend,
      relay_manual_ack_port: port,
      issue_identifier: "979",
      pending_line: "",
      pending_interrupt_request_id: nil,
      timeout_ms: :infinity,
      on_message: fn _ -> :ok end,
      held_native_questions: %{"held-ref" => %{request_id: 17}},
      on_native_reply: fn refs ->
        send(self(), {:checked_refs, refs})
        :none
      end
    }

    send(self(), {:agent_queue_updated, "979", 1, false})
    send(self(), {port, {:data, {:eol, ~s({"method":"done"})}}})
    assert {:ok, ^state} = TurnLoop.receive_loop(%{port: port}, state)
    assert_received {:checked_refs, ["held-ref"]}
  end
end
