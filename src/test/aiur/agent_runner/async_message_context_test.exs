defmodule Aiur.AgentRunner.AsyncMessageContextTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentQueue, AgentQueueStore, Issue, Listener, Orchestrator}
  alias Aiur.AgentRunner.TurnPrompt
  alias Aiur.Orchestrator.{ListenerModes, State}
  alias Aiur.Orchestrator.OperatorMessages.{Calls, HeldReads}

  defmodule Server do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: Orchestrator)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:listener_get_mode, id}, _from, state), do: ListenerModes.get_mode(state, id)
    def handle_call({:listener_set_mode, id, mode, opts}, _from, state), do: ListenerModes.set_mode(state, id, mode, opts)
    def handle_call({:control_capabilities, id}, _from, state), do: Calls.control_capabilities_call(state, id)
    def handle_call({:read_held_messages, id, max, deadline}, _from, state), do: HeldReads.handle_call(state, id, max, deadline: deadline)
  end

  setup do
    original = Process.whereis(Orchestrator)
    if original, do: Process.unregister(Orchestrator)
    on_exit(fn -> if original && Process.alive?(original), do: Process.register(original, Orchestrator) end)

    dir = Aiur.TestSupport.tmp_root!("async-prompt-context")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(dir)

    previous = Application.fetch_env(:aiur, :listener_send_routing)
    Application.put_env(:aiur, :listener_send_routing, :listener)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :listener_send_routing, value)
        :error -> Application.delete_env(:aiur, :listener_send_routing)
      end
    end)

    issue = %Issue{id: "prompt-internal", identifier: "prompt-count", title: "Prompt count", state: "in-progress", selected_backend: "codex"}
    entry = %{identifier: issue.identifier, issue: issue, session_execution: %{backend: "codex", pull_tool_installed: true}}

    store =
      Enum.reduce([{issue.identifier, :async}, {issue.identifier, :sync}, {"other-ticket", :async}], AgentQueueStore.new(), fn {id, mode}, store ->
        {next, _item} = AgentQueueStore.enqueue(store, AgentQueue.operator_message(id, "message", listener_mode: mode))
        next
      end)

    start_supervised!({Server, %State{running: %{issue.id => entry}, queue_store: store}})
    %{issue: issue}
  end

  test "default prompt reader gets the real held count and refreshes after consumption and a mode change", %{issue: issue} do
    # Mode changes restamp pending rows, so set async after the mixed queue fixture is installed.
    assert {:ok, %{effective: :async}} = Listener.set_mode(issue.identifier, :async, expected_version: 0)
    assert {:ok, %{listener: %{unread_count: 2}}} = Orchestrator.control_capabilities(issue.identifier)
    assert TurnPrompt.build_turn_prompt(issue, [spec_status: :ok], 1, nil) =~ "2 unread"

    assert {:ok, %{messages: messages, remaining: 0}} = Orchestrator.read_held_messages(issue.identifier)
    assert length(messages) == 2
    prompt = TurnPrompt.build_turn_prompt(issue, [spec_status: :ok], 2, nil)
    assert prompt =~ "Call `aiur_read_messages` at natural pauses and before finishing."
    refute prompt =~ " unread"

    assert {:ok, %{effective: :sync}} = Listener.set_mode(issue.identifier, :sync, expected_version: 1)
    refute TurnPrompt.build_turn_prompt(issue, [spec_status: :ok], 3, nil) =~ "aiur_read_messages"
  end
end
