Code.require_file("../../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.NativeCapture.CodexTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.AppServer.Interrupts
  alias Aiur.Codex.{Approvals, TurnLoop, TurnLoopTestSupport, UserInputAnswers}
  alias Aiur.Commands.NativeCapture
  alias Aiur.Config
  alias Aiur.Config.Schema
  alias Aiur.Events.Publisher
  alias Aiur.Workflow

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

  setup %{dir: dir} do
    previous = Application.get_env(:aiur, :workflow_file_path)
    File.mkdir_p!(dir)
    path = Path.join(dir, "config")
    File.write!(path, "tracker: {kind: memory}\n")
    Workflow.set_workflow_file_path(path)
    key = {Publisher, :tracked_fn}
    tracked = :persistent_term.get(key, nil)
    Publisher.set_tracked_fn(fn _ -> true end)

    on_exit(fn ->
      if is_nil(previous), do: Workflow.clear_workflow_file_path(), else: Workflow.set_workflow_file_path(previous)
      :persistent_term.put(key, tracked)
    end)

    store = start_store!(dir, dispatch_delay_ms: 60_000)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    relay = start_supervised!(RecordingRelay)
    ctx = %{ticket: @ticket, source: @source, session_ref: "thread-1-turn-1", tool_call_thread_id: "thread-1", turn_id: "turn-1", store: store, workspace: dir}
    %{ctx: ctx, relay: relay, path: path, store: store}
  end

  test "gate defaults off, rejects invalid values, and reloads through the accessor", %{path: path} do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.decisions.native_capture.codex == false
    assert Config.decisions_native_capture?(:codex) == false

    for value <- ["invalid", 123] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"decisions" => %{"native_capture" => %{"codex" => value}}})
      assert message =~ "codex"
    end

    enable(path)
    assert Config.decisions_native_capture?(:codex) == true
    File.write!(path, "tracker: {kind: memory}\n")
    assert :ok = Aiur.WorkflowStore.force_reload()
    assert Config.decisions_native_capture?(:codex) == false
  end

  test "gate off preserves the non-interactive frame and stores no Command (compatibility guard)", c do
    assert approve(c, fixture()) == :approved
    assert frames(c) == [%{"id" => 0, "result" => %{"answers" => %{"colour" => %{"answers" => [UserInputAnswers.non_interactive_answer()]}}}}]
    assert records(c) == ""
  end

  test "gate on captures trusted identity and holds without a response with either approval policy", c do
    enable(c.path)

    for {id, auto_approve} <- [{0, true}, {1, false}] do
      payload = Map.put(fixture(), "id", id)
      assert {:held, ref, info} = approve(c, payload, auto_approve)
      assert ref == "codex:thread-1:turn-1:#{id}"
      assert info.native_ref == ref
      assert info.request_id == id
      assert info.question_ids == ["colour"]
      assert %DateTime{} = info.since
      assert {:ok, d} = DecisionStore.get(info.decision_id, c.store)
      assert d.ticket.identifier == "979"
      assert d.source.session_id == "session-1"
      assert d.native.turn_id == "turn-1"
      assert d.native.call_id == "call_<id>"
      assert d.native.native_ref == ref
      assert d.native.hold == :in_band
      assert hd(d.questions).question == "Which colour should README.md mention: red or blue?"
    end

    assert frames(c) == []
  end

  test "gate on approval variants fall through to current policy without recording (compatibility guard)", c do
    enable(c.path)
    payload = put_in(fixture(), ["params", "questions", Access.at(0), "options"], [%{"label" => "Approve this Session"}, %{"label" => "Deny"}])
    assert approve(c, payload) == :approved
    assert approve(c, payload, false) == :approved

    assert frames(c) == [
             %{"id" => 0, "result" => %{"answers" => %{"colour" => %{"answers" => ["Approve this Session"]}}}},
             %{"id" => 0, "result" => %{"answers" => %{"colour" => %{"answers" => [UserInputAnswers.non_interactive_answer()]}}}}
           ]

    assert records(c) == ""
  end

  test "secret flag releases every question without storing secret text, even for approval labels", c do
    enable(c.path)
    payload = put_in(fixture(), ["params", "questions", Access.at(0), "isSecret"], true)
    payload = put_in(payload, ["params", "questions", Access.at(0), "options"], [%{"label" => "Approve Once"}, %{"label" => "Deny"}])
    second = payload["params"]["questions"] |> hd() |> Map.put("id", "second")
    payload = update_in(payload, ["params", "questions"], &(&1 ++ [second]))
    capture_log(fn -> assert approve(c, payload) == :approved end)
    assert [%{"id" => 0, "result" => %{"answers" => answers}}] = frames(c)
    assert answers == Map.new(["colour", "second"], &{&1, %{"answers" => [NativeCapture.secret_release_text()]}})
    assert records(c) == ""
  end

  test "missing question ids keep input_required and unavailable store releases (compatibility guard)", c do
    enable(c.path)
    invalid = update_in(fixture(), ["params", "questions"], fn [q] -> [Map.delete(q, "id")] end)
    assert approve(c, invalid) == :input_required
    assert frames(c) == []
    GenServer.stop(c.store)
    capture_log(fn -> assert approve(c, fixture()) == :approved end)
    assert [%{"result" => %{"answers" => %{"colour" => %{"answers" => [text]}}}}] = frames(c)
    assert text == UserInputAnswers.non_interactive_answer()
  end

  test "an answer already queued when the hold starts replies before another notification", c do
    enable(c.path)
    owner = self()

    state =
      TurnLoopTestSupport.base_state(fn _ -> :noop end)
      |> Map.merge(%{
        issue: @ticket,
        issue_identifier: "979",
        held_native_questions: %{},
        on_message: fn msg -> send(owner, {:update, msg}) end,
        on_native_reply: fn [ref] ->
          {:reply, ref, %{"colour" => ["red"]}, fn metadata -> send(owner, {:delivered, metadata}) end, fn reason -> flunk(inspect(reason)) end}
        end
      })

    session = %{port: c.relay, thread_id: "thread-1", workspace: c.dir, store: c.store, metadata: %{}}
    payload = fixture()
    assert {:continue, next} = TurnLoop.handle_method(session, state, payload, Jason.encode!(payload), payload["method"])
    assert next.held_native_questions == %{}
    assert frames(c) == [%{"id" => 0, "result" => %{"answers" => %{"colour" => %{"answers" => ["red"]}}}}]
    assert_received {:update, %{event: :native_question_held, native_ref: ref}}
    assert_received {:update, %{event: :native_question_resolved, native_ref: ^ref, reason: :answered}}
    assert_received {:delivered, %{provider: :native_reply, native_ref: ^ref}}
  end

  test "turn handler tracks two held requests, emits events, skips checkpoints and defers unrelated queue items", c do
    enable(c.path)
    owner = self()

    state =
      TurnLoopTestSupport.base_state(fn checkpoint ->
        send(owner, {:checkpoint, checkpoint})
        :noop
      end)
      |> Map.merge(%{issue: @ticket, issue_identifier: "979", held_native_questions: %{}, on_message: fn msg -> send(owner, {:update, msg}) end})

    session = %{port: c.relay, thread_id: "thread-1", workspace: c.dir, store: c.store}

    next =
      Enum.reduce([0, 1], state, fn id, acc ->
        payload = Map.put(fixture(), "id", id)
        assert {:continue, next} = TurnLoop.handle_method(session, acc, payload, Jason.encode!(payload), payload["method"])
        ref = "codex:thread-1:turn-1:#{id}"
        assert_received {:update, %{event: :native_question_held, native_ref: ^ref, decision_id: decision_id, since: %DateTime{}}}
        assert {:ok, d} = DecisionStore.get(decision_id, c.store)
        assert d.ticket.identifier == "979"
        assert d.source.session_id == "thread-1-turn-1"
        next
      end)

    assert Map.keys(next.held_native_questions) |> Enum.sort() == ["codex:thread-1:turn-1:0", "codex:thread-1:turn-1:1"]
    assert {:continue, ^next} = Interrupts.handle_operator_queue_update(session, next)
    assert frames(c) == []
    refute_received {:checkpoint, _}
  end

  test "pause-latched requests bypass capture (compatibility guard)", c do
    enable(c.path)
    payload = fixture()
    assert :approved = Approvals.maybe_handle_approval_request(c.relay, payload["method"], payload, Jason.encode!(payload), fn _ -> :ok end, %{}, fn _, _ -> :ok end, true, c.ctx, true)
    assert frames(c) == [%{"id" => 0, "result" => %{"decision" => "declined"}}]
    assert records(c) == ""
  end

  defp fixture do
    Path.expand("../../../fixtures/codex/request_user_input/request_user_input.json", __DIR__) |> File.read!() |> Jason.decode!()
  end

  defp approve(c, payload, auto_approve \\ true) do
    Approvals.maybe_handle_approval_request(c.relay, payload["method"], payload, Jason.encode!(payload), fn _ -> :ok end, %{}, fn _, _ -> :ok end, auto_approve, c.ctx, false)
  end

  defp frames(c), do: GenServer.call(c.relay, :frames)
  defp records(c), do: File.read!(Path.join(c.dir, "decisions.ndjson"))

  defp enable(path) do
    File.write!(path, "tracker: {kind: memory}\ndecisions: {native_capture: {codex: true}}\n")
    assert :ok = Aiur.WorkflowStore.force_reload()
  end
end
