defmodule Aiur.AppServer.TurnLoopTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.{Rpc, TurnLoop}

  defmodule StubBackend do
    def send_frame(_port, frame) do
      send(self(), {:frame, frame})
      :ok
    end

    def metadata_from_message(_port, _payload), do: %{backend: :stub}
    def handle_interrupt_error(_state, error), do: {:error, {:turn_interrupt_failed, error}}
    def handle_malformed(state, payload, _port), do: send(state.parent, {:malformed, payload}) && {:continue, state}

    def handle_method(_session, _state, %{"method" => "done"}, _payload_string, _method) do
      {:ok, :done}
    end

    def handle_method(_session, state, payload, _payload_string, _method) do
      send(state.parent, {:method, payload})
      {:continue, state}
    end
  end

  test "reassembles no-eol/eol chunks before dispatch" do
    port = cat_port()
    parent = self()

    send(self(), {port, {:data, {:noeol, ~s({"method":)}}})
    send(self(), {port, {:data, {:eol, ~s("done"})}}})

    assert TurnLoop.receive_loop(%{port: port}, state(%{parent: parent})) == {:ok, :done}
  end

  test "returns port exit and idle timeout errors" do
    port = cat_port()
    send(self(), {port, {:exit_status, 9}})
    assert TurnLoop.receive_loop(%{port: port}, state()) == {:error, {:port_exit, 9}}

    assert TurnLoop.receive_loop(%{port: port}, state(%{timeout_ms: 1})) == {:error, :turn_timeout}
  end

  test "pause_agent and deliver-now queue update interrupt the turn" do
    port = cat_port()

    send(self(), {:pause_agent, 7})
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"id" => 123, "result" => %{}})}}})

    assert {:error, :turn_timeout} = TurnLoop.receive_loop(%{port: port, thread_id: "thread-1"}, state(%{timeout_ms: 1}))
    assert_receive {:frame, %{"method" => "turn/interrupt"}}

    port = cat_port()
    send(self(), {:agent_queue_updated, "ISSUE-1", "item-1", true})
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"id" => 124, "result" => %{}})}}})

    assert {:error, :turn_timeout} = TurnLoop.receive_loop(%{port: port, thread_id: "thread-1"}, state(%{timeout_ms: 1}))
    assert_receive {:frame, %{"method" => "turn/interrupt"}}
  end

  test "queue update ignore shapes are drained" do
    port = cat_port()

    send(self(), {:agent_queue_updated, "ISSUE-1", "item-1", false})
    send(self(), {:agent_queue_updated, "ISSUE-1", "item-1"})
    send(self(), {:agent_queue_updated, "OTHER", "item-1", true})
    send(self(), {:agent_queue_updated, "OTHER", "item-1"})
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "done"})}}})

    assert TurnLoop.receive_loop(%{port: port}, state()) == {:ok, :done}
  end

  test "interrupt ack is handled before operator response clauses" do
    port = cat_port()
    parent = self()

    state =
      state(%{
        parent: parent,
        pending_interrupt_request_id: 42,
        pending_operator_requests: %{42 => %{on_success: fn _ -> send(parent, :wrong) end, on_failure: fn _ -> :ok end}}
      })

    send(self(), {port, {:data, {:eol, Jason.encode!(%{"id" => 42, "result" => %{}})}}})
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "done"})}}})

    assert TurnLoop.receive_loop(%{port: port}, state) == {:ok, :done}
    refute_receive :wrong
  end

  test "drops late sensitive response data before the turn loop can emit it" do
    port = cat_port()
    raw_identity = "person@example.test credential=super-secret"
    parent = self()

    Rpc.retain_late_sensitive_response(port, 5)
    on_exit(fn -> Rpc.clear_late_sensitive_responses(port) end)

    late_response =
      Jason.encode!(%{
        "id" => 5,
        "result" => %{"account" => %{"email" => raw_identity, "planType" => "plus"}}
      })

    send(self(), {port, {:data, {:eol, late_response}}})
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "done"})}}})

    state = state(%{on_message: fn message -> send(parent, {:event, message}) end})

    assert TurnLoop.receive_loop(%{port: port}, state) ==
             {:ok, :done}

    refute_receive {:event, _event}
  end

  test "keeps malformed late sensitive stream data out of turn-loop events" do
    port = cat_port()
    raw_identity = "person@example.test credential=super-secret"
    parent = self()

    Rpc.retain_late_sensitive_response(port, 5)
    on_exit(fn -> Rpc.clear_late_sensitive_responses(port) end)

    send(self(), {port, {:data, {:eol, "malformed delayed account=#{raw_identity}"}}})
    send(self(), {port, {:data, {:eol, Jason.encode!(%{"method" => "done"})}}})

    state = state(%{on_message: fn message -> send(parent, {:event, message}) end, timeout_ms: 1})

    assert TurnLoop.receive_loop(%{port: port}, state) ==
             {:error, :turn_timeout}

    refute_receive {:malformed, _payload}
    refute_receive {:event, _event}
  end

  defp cat_port do
    port =
      Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [
        :binary,
        :exit_status,
        line: 64_000
      ])

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end)

    port
  end

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        backend: StubBackend,
        parent: self(),
        on_message: fn _ -> :ok end,
        on_safe_checkpoint: fn _ -> :noop end,
        tool_executor: fn _, _ -> %{} end,
        timeout_ms: 50,
        pending_line: "",
        outstanding_turns: 1,
        pending_operator_requests: %{},
        current_turn_id: "turn-1",
        issue_identifier: "ISSUE-1",
        pause_request_id: nil,
        pending_interrupt_request_id: nil,
        interrupt_action: nil
      },
      overrides
    )
  end
end
