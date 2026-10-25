defmodule Aiur.Claude.ToolCallHandoffTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.ToolCallLedger
  alias Aiur.Claude.CodingAgent.Methods

  defmodule Transport do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}
    def handle_call(:metadata, _from, owner), do: {:reply, %{provider_pid: 1, relay_id: "claude-relay"}, owner}

    def handle_call({:command, line}, _from, owner) do
      send(owner, {:provider_response, Jason.decode!(line)})
      {:reply, true, owner}
    end
  end

  setup do
    ledger = start_supervised!({ToolCallLedger, name: nil})
    port = start_supervised!({Transport, self()})
    session = %{port: port, thread_id: "thread", workspace: System.tmp_dir!()}
    state = %{outstanding_turns: 1, issue_identifier: "claude-#{System.unique_integer([:positive])}", tool_call_ledger: ledger, on_message: fn _ -> :ok end}
    payload = %{"id" => 101, "method" => "item/tool/call", "params" => %{"name" => "emit_event", "arguments" => %{"name" => "progress"}}}
    %{ledger: ledger, session: session, state: state, payload: payload}
  end

  test "Claude replays the same tool request with one side effect and the same response", context do
    parent = self()

    state =
      Map.put(context.state, :tool_executor, fn _, _ ->
        send(parent, :side_effect)
        %{"success" => true, "output" => "recorded"}
      end)

    assert {:continue, ^state} = handle(context.session, state, context.payload)
    assert_receive :side_effect, 1000
    assert_receive {:provider_response, %{"id" => 101, "result" => %{"success" => true, "output" => "recorded"}} = response}, 1000
    assert {:continue, ^state} = handle(context.session, state, context.payload)
    assert_receive {:provider_response, ^response}, 1000
    refute_receive :side_effect, 30
  end

  test "quiescing a blocked Claude tool releases the runner and refuses replay", context do
    parent = self()

    state =
      Map.put(context.state, :tool_executor, fn _, _ ->
        send(parent, {:tool_running, self()})

        receive do
          :never_sent -> %{"success" => true, "output" => "late"}
        end
      end)

    runner = Task.async(fn -> handle(context.session, state, context.payload) end)
    assert_receive {:tool_running, worker}, 1000
    monitor = Process.monitor(worker)
    assert :ok = ToolCallLedger.quiesce(0, context.ledger)
    assert {:continue, ^state} = Task.await(runner, 1000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1000
    assert_receive {:provider_response, %{"result" => %{"success" => false, "output" => output}}}, 1000
    assert output =~ "uncertain"
    assert {:continue, ^state} = handle(context.session, state, context.payload)
    assert_receive {:provider_response, %{"result" => %{"success" => false, "output" => ^output}}}, 1000
    refute_receive {:tool_running, _}, 30
  end

  defp handle(session, state, payload), do: Methods.handle_method(session, state, payload, Jason.encode!(payload), "item/tool/call")
end
