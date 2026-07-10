defmodule Aiur.AppServer.InterruptsTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.Interrupts

  defmodule StubBackend do
    def send_frame(_port, frame) do
      send(self(), {:frame, frame})
      :ok
    end
  end

  test "pause request dedupes same and different ids while pending" do
    state = state(%{pause_request_id: 7})

    assert {:continue, ^state} = Interrupts.handle_pause_request(session(), state, 7)
    assert {:continue, ^state} = Interrupts.handle_pause_request(session(), state, 8)
  end

  test "pause request sends interrupt and records request ids" do
    assert {:continue, next_state} = Interrupts.handle_pause_request(session(), state(), 7)

    assert next_state.pause_request_id == 7
    assert is_integer(next_state.pending_interrupt_request_id)
    assert next_state.interrupt_action == :pause
    assert_receive {:frame, %{"method" => "turn/interrupt", "params" => %{"turnId" => "turn-1"}}}
  end

  test "operator queue update dedupes in-flight interrupt" do
    state = state(%{pending_interrupt_request_id: 12})
    assert {:continue, ^state} = Interrupts.handle_operator_queue_update(session(), state)
  end

  test "operator queue update sends interrupt for deliver-now message" do
    assert {:continue, next_state} = Interrupts.handle_operator_queue_update(session(), state())

    assert is_integer(next_state.pending_interrupt_request_id)
    assert next_state.interrupt_action == :operator_message
    assert_receive {:frame, %{"id" => request_id, "params" => %{"threadId" => "thread-1", "turnId" => "turn-1"}}}
    assert is_integer(request_id)
  end

  test "interrupt_turn returns invalid_session fallback" do
    assert Interrupts.interrupt_turn(StubBackend, %{}, "turn-1") == {:error, :invalid_session}
  end

  defp session do
    port =
      Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [
        :binary,
        :exit_status
      ])

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end)

    %{port: port, thread_id: "thread-1"}
  end

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        backend: StubBackend,
        current_turn_id: "turn-1",
        pause_request_id: nil,
        pending_interrupt_request_id: nil,
        interrupt_action: nil
      },
      overrides
    )
  end
end
