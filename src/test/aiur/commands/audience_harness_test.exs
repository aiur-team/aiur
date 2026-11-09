defmodule Aiur.Commands.AudienceHarnessTest do
  # Each harness hands a worker's emit_event call to Aiur through its own
  # transport; the audience must survive every one into the stored Decision.
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.AppServer.ToolCallLedger
  alias Aiur.Claude.CodingAgent.Methods
  alias Aiur.Codex.Approvals
  alias Aiur.{DecisionStore, Issue}
  alias Aiur.OpenAICompat.Tools

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

  defp arguments do
    %{
      "name" => "decision.requested",
      "message" => "Which index should the migration add?",
      "payload" => %{"blocking" => false, "audience" => "executor"}
    }
  end

  defp executor(backend) do
    identifier = "AUD-#{backend}-#{System.unique_integer([:positive])}"
    {identifier, ToolExecutor.build(%Issue{identifier: identifier}, nil, nil, %{backend: backend, thread_id: "thread-#{backend}"})}
  end

  defp stored_audience(identifier) do
    [decision] = DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
    decision.audience
  end

  test "Codex app-server: item/tool/call keeps the audience" do
    {identifier, tool_executor} = executor("codex")
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status, {:line, 64_000}])
    payload = %{"id" => "t1", "method" => "item/tool/call", "params" => %{"tool" => "emit_event", "arguments" => arguments()}}

    try do
      assert :approved =
               Approvals.maybe_handle_approval_request(port, "item/tool/call", payload, Jason.encode!(payload), fn _ -> :ok end, %{backend: "codex"}, tool_executor, false)
    after
      Port.close(port)
    end

    assert stored_audience(identifier) == :executor
  end

  test "Claude: item/tool/call keeps the audience" do
    {identifier, tool_executor} = executor("claude")
    ledger = start_supervised!({ToolCallLedger, name: nil})
    port = start_supervised!({Transport, self()})
    session = %{port: port, thread_id: "thread", workspace: System.tmp_dir!()}
    state = %{outstanding_turns: 1, issue_identifier: identifier, tool_call_ledger: ledger, on_message: fn _ -> :ok end, tool_executor: tool_executor}
    payload = %{"id" => 7, "method" => "item/tool/call", "params" => %{"name" => "emit_event", "arguments" => arguments()}}

    assert {:continue, _state} = Methods.handle_method(session, state, payload, Jason.encode!(payload), "item/tool/call")
    assert_receive {:provider_response, %{"id" => 7, "result" => %{"success" => true}}}, 5_000
    assert stored_audience(identifier) == :executor
  end

  test "open_ai_compat: the emit_event function keeps the audience" do
    {identifier, tool_executor} = executor("openrouter")
    assert {:ok, decoded} = Tools.decode_and_validate("emit_event", Jason.encode!(arguments()))
    assert Tools.execute("emit_event", decoded, %{workspace: nil, tool_executor: tool_executor}, [])["success"] == true
    assert stored_audience(identifier) == :executor
  end
end
