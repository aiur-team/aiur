defmodule Aiur.Commands.NativeCapture.ClaudeFallbackTest do
  use Aiur.TestSupport

  alias Aiur.Claude.CodingAgent
  alias Aiur.Codex.{TurnLoopTestSupport, UserInputAnswers}
  alias Aiur.Commands.NativeCapture
  alias Aiur.DecisionStore
  alias Aiur.Events.Publisher
  alias Aiur.PauseContainment
  alias Aiur.Workflow

  @issue %{id: "native-fallback", identifier: "native-fallback", title: "Native fallback"}

  defmodule RecordingRelay do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, [])
    @impl true
    def init(frames), do: {:ok, frames}
    @impl true
    def handle_call({:command, line}, _from, frames), do: {:reply, true, frames ++ [Jason.decode!(line)]}
    def handle_call(:frames, _from, frames), do: {:reply, frames, frames}
    def handle_call(:metadata, _from, frames), do: {:reply, %{}, frames}
  end

  setup do
    root = Aiur.TestSupport.tmp_root!("claude-native-fallback")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude", workspace_root: root)
    File.write!(Workflow.workflow_file_path(), "\ndecisions: {native_capture: {claude: true}}\n", [:append])
    assert :ok = Aiur.WorkflowStore.force_reload()
    key = {Publisher, :tracked_fn}
    previous = :persistent_term.get(key, nil)
    Publisher.set_tracked_fn(fn _ -> true end)
    on_exit(fn -> :persistent_term.put(key, previous) end)
    store = start_supervised!({DecisionStore, name: nil, state_dir: root, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000})
    relay = start_supervised!(RecordingRelay)
    session = %{port: relay, thread_id: "thread", metadata: %{}, workspace: root, store: store, native_question_capability: %{native_question: :deferred}}
    state = TurnLoopTestSupport.base_state() |> Map.merge(%{backend: CodingAgent, issue: @issue, held_native_questions: %{}})
    %{root: root, store: store, relay: relay, session: session, state: state}
  end

  test "gate-on approval-shaped question replies exactly once without creating a Command", c do
    payload = put_in(request(), ["params", "questions", Access.at(0), "options"], [%{"label" => "Approve Once"}, %{"label" => "Deny"}])
    assert_fallback(c, c.session, c.state, payload, unavailable())
  end

  test "gate-on invalid question replies exactly once with a protocol error", c do
    payload = update_in(request(), ["params", "questions", Access.at(0)], &Map.delete(&1, "id"))
    error = %{"jsonrpc" => "2.0", "id" => "native-1", "error" => %{"code" => -32_602, "message" => "Invalid native question parameters"}}
    assert_fallback(c, c.session, c.state, payload, error)
  end

  test "latched pause answers without holding or capturing a new question", c do
    assert_fallback(c, c.session, %{c.state | pause_request_id: 77}, request(), unavailable())
  end

  test "confirmed containment answers without holding or capturing a new question", c do
    identifier = "native-fallback-#{System.unique_integer([:positive])}"
    assert {:ok, handle} = PauseContainment.register(identifier, 999_999_999, 999_999_999)
    on_exit(fn -> PauseContainment.unregister(handle) end)
    assert {:ok, ^handle} = PauseContainment.arm(identifier)
    assert :ok = PauseContainment.confirm(handle)
    assert PauseContainment.paused?(handle)
    assert_fallback(c, Map.put(c.session, :containment, handle), c.state, request(), unavailable())
  end

  test "interrupted turn releases its real held question and leaves the Command open", c do
    {state, info} = hold(c)
    payload = %{"method" => "turn/completed", "params" => %{"status" => "interrupted"}}
    assert {:error, {:turn_interrupted, ^payload}} = dispatch(c.session, state, payload)
    assert_release(c, info)
  end

  test "failed turn releases its real held question and leaves the Command open", c do
    {state, info} = hold(c)
    params = %{"error" => "Native worker failed"}
    assert {:error, {:turn_failed, ^params}} = dispatch(c.session, state, %{"method" => "turn/failed", "params" => params})
    assert_release(c, info)
  end

  defp assert_fallback(c, session, state, payload, expected) do
    assert {:continue, next} = dispatch(session, state, payload)
    assert next.held_native_questions == %{}
    assert GenServer.call(c.relay, :frames) == [expected]
    assert File.read!(Path.join(c.root, "decisions.ndjson")) == ""
  end

  defp hold(c) do
    assert {:continue, state} = dispatch(c.session, c.state, request())
    assert [info] = Map.values(state.held_native_questions)
    assert GenServer.call(c.relay, :frames) == []
    assert {:ok, decision} = DecisionStore.get(info.decision_id, c.store)
    assert decision.native.harness == :claude
    {state, info}
  end

  defp assert_release(c, info) do
    assert GenServer.call(c.relay, :frames) == [
             %{"jsonrpc" => "2.0", "id" => "native-1", "result" => %{"answers" => %{"colour" => %{"answers" => [NativeCapture.release_text(info.decision_id)]}}}}
           ]

    assert {:ok, decision} = DecisionStore.get(info.decision_id, c.store)
    assert decision.answer == nil
    assert decision.decision_status == :open
  end

  defp dispatch(session, state, payload), do: CodingAgent.handle_method(session, state, payload, Jason.encode!(payload), payload["method"])

  defp unavailable do
    %{"jsonrpc" => "2.0", "id" => "native-1", "result" => %{"answers" => %{"colour" => %{"answers" => [UserInputAnswers.non_interactive_answer()]}}}}
  end

  defp request do
    %{
      "method" => "item/tool/requestUserInput",
      "id" => "native-1",
      "params" => %{
        "itemId" => "tool-1",
        "questions" => [
          %{"id" => "colour", "header" => "Colour", "question" => "Which colour?", "options" => [%{"label" => "red", "description" => "Red"}, %{"label" => "blue", "description" => "Blue"}]}
        ]
      }
    }
  end
end
