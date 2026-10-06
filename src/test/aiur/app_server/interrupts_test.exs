defmodule Aiur.AppServer.InterruptsTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.Interrupts
  alias Aiur.Codex.CodingAgent

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
    assert_receive {:frame, %{"method" => "turn/interrupt", "params" => %{"turnId" => "turn-1"}}}, 1000
  end

  test "operator queue update dedupes in-flight interrupt" do
    state = state(%{pending_interrupt_request_id: 12})
    assert {:continue, ^state} = Interrupts.handle_operator_queue_update(session(), state)
  end

  test "operator queue update sends interrupt for deliver-now message" do
    assert {:continue, next_state} = Interrupts.handle_operator_queue_update(session(), state())

    assert is_integer(next_state.pending_interrupt_request_id)
    assert next_state.interrupt_action == :operator_message
    assert_receive {:frame, %{"id" => request_id, "params" => %{"threadId" => "thread-1", "turnId" => "turn-1"}}}, 1000
    assert is_integer(request_id)
  end

  test "interrupt_turn returns invalid_session fallback" do
    assert Interrupts.interrupt_turn(StubBackend, %{}, "turn-1") == {:error, :invalid_session}
  end

  test "a closed Codex port returns a typed interrupt failure" do
    port =
      Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [
        :binary,
        :exit_status
      ])

    true = Port.close(port)

    assert {:error, {:turn_interrupt_failed, :port_closed}} =
             Interrupts.handle_operator_queue_update(
               %{port: port, thread_id: "thread-1"},
               %{backend: CodingAgent, current_turn_id: "queued-turn"}
             )
  end

  test "a retired-turn interrupt fails pending operator requests before returning its boundary" do
    parent = self()
    error = %{"code" => -32_004, "message" => "No active turn to interrupt."}

    state =
      state(%{
        active_turn_ids: MapSet.new(),
        retired_turn_ids: MapSet.new(["turn-1"]),
        pending_interrupt_request_id: 12,
        interrupt_action: :operator_message,
        pending_operator_requests: %{
          99 => %{
            on_success: fn _ -> :ok end,
            on_failure: fn reason -> send(parent, {:operator_request_failed, reason}) end
          }
        }
      })

    assert Interrupts.handle_no_active_turn_error(state, error) ==
             {:ok, :turn_interrupted_for_operator_message}

    assert_receive {:operator_request_failed, {:turn_interrupted, %{"error" => ^error, "status" => "interrupted"}}},
                   1000
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
