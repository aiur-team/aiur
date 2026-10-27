defmodule Aiur.Commands.NativeCapture.ClaudeTest do
  use Aiur.TestSupport

  alias Aiur.AppServer.{Rpc, Transport}
  alias Aiur.Claude.CodingAgent
  alias Aiur.Codex.UserInputAnswers
  alias Aiur.Commands.{NativeAnswer, NativeCapture}
  alias Aiur.Config
  alias Aiur.Config.Schema
  alias Aiur.AgentTools.Catalog
  alias Aiur.Codex.TurnLoopTestSupport
  alias Aiur.DecisionStore
  alias Aiur.Events.Publisher
  alias Aiur.Workflow

  @fixture Path.expand("../../../fixtures/aiur_claude/protocol-1.3.0-native.ndjson", __DIR__)
  @peer Path.expand("../../../fixtures/aiur_claude/replay.py", __DIR__)
  @issue %{id: "protocol", identifier: "fixture", title: "Protocol fixture"}

  setup do
    root = Aiur.TestSupport.tmp_root!("claude-native")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    key = {Publisher, :tracked_fn}
    previous = :persistent_term.get(key, nil)
    Publisher.set_tracked_fn(fn _ -> true end)
    on_exit(fn -> :persistent_term.put(key, previous) end)
    store = start_supervised!({DecisionStore, name: nil, state_dir: root, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000})
    %{root: root, store: store}
  end

  test "default-off Claude gate validates and reloads", c do
    assert Config.decisions_native_capture?(:claude) == false
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"decisions" => %{"native_capture" => %{"claude" => "bad"}}})
    configure(c, true, "false")
    assert Config.decisions_native_capture?(:claude) == true
  end

  for {name, gate, version, reason} <- [
        {"gate off", false, "1.3.0", :gate_off},
        {"old sibling", true, "1.2.0", :sibling_too_old},
        {"unversioned sibling", true, nil, :sibling_too_old},
        {"invalid sibling version", true, "unknown", :sibling_too_old},
        {"prerelease sibling", true, "1.3.0-rc.1", :sibling_too_old}
      ] do
    test "#{name} omits nativeQuestions and answers defensively", c do
      run_scenario(c, unquote(gate), unquote(version), unquote(reason))
    end
  end

  test "supported sibling captures a deferred Command and delivers its structured answer", c do
    run_scenario(c, true, "1.3.0", nil)
  end

  test "newer sibling captures a deferred Command", c do
    run_scenario(c, true, "1.4.0", nil)
  end

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

  test "completed turn releases a pending question without resolving the Command", c do
    configure(c, true, "false")
    relay = start_supervised!(RecordingRelay)
    session = %{port: relay, thread_id: "thread", metadata: %{}, workspace: c.root, store: c.store, native_question_capability: %{native_question: :deferred}}

    state =
      TurnLoopTestSupport.base_state()
      |> Map.merge(%{backend: CodingAgent, issue: @issue, held_native_questions: %{}})

    request = File.read!(@fixture) |> String.split("\n", trim: true) |> Enum.at(9) |> Jason.decode!() |> Map.fetch!("msg")
    assert {:continue, state} = CodingAgent.handle_method(session, state, request, "", request["method"])
    assert [info] = Map.values(state.held_native_questions)
    assert GenServer.call(relay, :frames) == []
    completed = %{"method" => "turn/completed", "params" => %{"status" => "completed"}}
    assert {:ok, :turn_completed} = CodingAgent.handle_method(session, state, completed, "", "turn/completed")

    assert GenServer.call(relay, :frames) == [
             %{"jsonrpc" => "2.0", "id" => "native-question-1", "result" => %{"answers" => %{"colour" => %{"answers" => [NativeCapture.release_text(info.decision_id)]}}}}
           ]

    assert {:ok, decision} = DecisionStore.get(info.decision_id, c.store)
    assert decision.answer == nil
    assert decision.decision_status == :open
  end

  defp run_scenario(c, gate, version, reason) do
    {session, frames, rows} = peer(c, gate, version, reason)
    expected = if reason, do: :none, else: :deferred
    assert session.native_question_capability == %{native_question: expected, reason: reason}
    assert session.metadata.native_question_capability == session.native_question_capability
    owner = self()
    on_message = fn event -> send(owner, {:event, event}) end

    reply = fn [ref] ->
      assert_received {:event, %{event: :native_question_held, decision_id: id, native_ref: ^ref}}
      assert {:ok, decision} = DecisionStore.get(id, c.store)
      assert decision.native.harness == :claude
      assert decision.native.hold == :deferred
      assert decision.native.call_id == "tool-1"
      assert decision.native.turn_id == "<turn>"
      assert decision.ticket.identifier == "fixture"
      assert decision.source.session_id == "<thread>-<turn>"
      assert decision.questions |> hd() |> Map.fetch!(:question) == "Should README.md mention red or blue?"
      answer = %{selected_option_id: "o1", custom_response: nil}
      correlation = NativeAnswer.correlate(decision, answer, %{})
      assert correlation == %{native_ref: ref, question_answers: %{"colour" => ["red"]}}
      {:reply, ref, correlation.question_answers, fn _ -> send(owner, :delivered) end, fn failure -> flunk(inspect(failure)) end}
    end

    assert {:ok, %{result: :turn_completed}} = CodingAgent.run_turn(session, "Protocol fixture prompt", @issue, on_message: on_message, on_native_reply: reply)

    if reason do
      refute_received {:event, %{event: :native_question_held}}
      assert File.read!(Path.join(c.root, "decisions.ndjson")) == ""
    else
      assert_received :delivered
      assert_received {:event, %{event: :native_question_resolved, reason: :answered}}
    end

    finish(session, length(rows))
    actual = File.read!(frames) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert actual == for(%{"dir" => "out", "msg" => frame} <- rows, do: frame)
  end

  defp peer(c, gate, version, reason) do
    workspace = Path.join(c.root, "worker")
    File.mkdir_p!(workspace)
    frames = Path.join(c.root, "frames")
    replay = Path.join(c.root, "replay")
    rows = File.read!(@fixture) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    rows = Enum.map(rows, &expand(&1, workspace))
    rows = put_in(rows, [Access.at(1), "msg", "result", "server", "version"], version)
    rows = if reason in [nil, :release], do: rows, else: fallback_rows(rows)
    File.write!(replay, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
    command = Enum.map_join(["python3", @peer, replay, frames], " ", &Aiur.Shell.escape/1)
    configure(c, gate, command)
    assert {:ok, session} = CodingAgent.start_session(workspace)
    session = Map.put(session, :store, c.store)
    on_exit(fn -> CodingAgent.stop_session(session) end)
    {session, frames, rows}
  end

  defp fallback_rows(rows) do
    rows = update_in(rows, [Access.at(4), "msg", "params"], &Map.delete(&1, "nativeQuestions"))
    rows = update_in(rows, [Access.at(10), "msg"], &Map.put(&1, "jsonrpc", "2.0"))
    put_in(rows, [Access.at(10), "msg", "result", "answers", "colour", "answers"], [UserInputAnswers.non_interactive_answer()])
  end

  defp finish(session, count) do
    assert true = Transport.command(session.port, Jason.encode!(%{"replay" => "done"}) <> "\n")
    assert {:ok, %{"replayed" => ^count}} = Rpc.with_timeout_response(session.port, 999_999, 5_000, "", "Claude")
  end

  defp configure(c, gate, command) do
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude", workspace_root: c.root, command: command, agent_read_timeout_ms: 5_000)
    File.write!(Workflow.workflow_file_path(), "\ndecisions: {native_capture: {claude: #{gate}}}\n", [:append])
    assert :ok = Aiur.WorkflowStore.force_reload()
  end

  defp expand("<workspace>", workspace), do: workspace
  defp expand("<client-version>", _), do: Mix.Project.config()[:version]
  defp expand("<dynamic-tools>", _), do: Catalog.specs()
  defp expand(value, workspace) when is_map(value), do: Map.new(value, fn {k, v} -> {k, expand(v, workspace)} end)
  defp expand(value, workspace) when is_list(value), do: Enum.map(value, &expand(&1, workspace))
  defp expand(value, _), do: value
end
