defmodule Aiur.VoiceConversation.SessionTest do
  use Aiur.TestSupport

  alias Aiur.VoiceConversation.Session
  alias VoiceConverse.{Config, Events, SessionRegistry, TranscriptStore}
  alias VoiceConverse.Testing.{FakeBriefingSource, FakeProvider, StaticCredentials}

  setup do
    root = Aiur.TestSupport.tmp_root!("executor-voice-session")
    instance = Module.concat(__MODULE__, "Instance#{System.unique_integer([:positive])}")
    credentials_key = {StaticCredentials, :secrets}
    previous_credentials = :persistent_term.get(credentials_key, :missing)

    on_exit(fn ->
      case previous_credentials do
        :missing -> :persistent_term.erase(credentials_key)
        previous -> :persistent_term.put(credentials_key, previous)
      end
    end)

    StaticCredentials.put(%{fake: "test"})

    {:ok, config} =
      Config.new(name: instance, transcript_root: root, credentials: StaticCredentials, briefing_source: FakeBriefingSource, provider: FakeProvider, llm: "test", cloud_disclosure_accepted: true)

    start_supervised!(VoiceConverse.child_spec(config))
    test_pid = self()

    start = fn owner, _opts ->
      VoiceConverse.start_session(instance, %{id: "executor"},
        client: owner,
        provider: {FakeProvider, [script: [%Events.ProviderConversationId{id: "p"}], call_observer: test_pid]}
      )
    end

    deliver = fn id, turns, reason ->
      send(test_pid, {:delivered, id, turns, reason})
      {:ok, %{id: 123, topic: "executor.voice.session_ended", at: "test-clock", status: "queued"}}
    end

    %{opts: [instance: instance, start_session: start, deliver: deliver], instance: instance}
  end

  test "end sends redacted transcript and receipt before the ended event", %{opts: opts, instance: instance} do
    {:ok, monitor, id} = Session.start(self(), opts)
    ref = Process.monitor(monitor)
    {:ok, session} = SessionRegistry.lookup(instance, id)
    provider = :sys.get_state(session).provider_ref
    FakeProvider.emit(provider, %Events.UserTranscript{text: "Check builds", final?: true})
    FakeProvider.emit(provider, %Events.AgentText{turn_id: "a", text: "Bearer abcdefgh12345", final?: true})
    receive_barrier({:executor_voice, %Events.AgentText{text: broadcast_text}})
    assert broadcast_text =~ "[redacted]"
    refute broadcast_text =~ "abcdefgh12345"
    Session.stop(monitor)
    receive_barrier({:delivered, ^id, [%{role: "user", text: "Check builds"}, %{role: "agent", text: text}], :user_end})
    assert text =~ "[redacted]"
    refute text =~ "abcdefgh12345"
    receive_barrier({:executor_voice, {:receipt, %{id: 123, status: "queued"}}})
    receive_barrier({:executor_voice, {:ended, :user_end}})
    receive_barrier({:DOWN, ^ref, :process, ^monitor, :normal})
    refute_received {:delivered, ^id, _, _}
  end

  test "browser disconnect still hands off its last partial user transcript", %{opts: opts, instance: instance} do
    owner =
      spawn_link(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, monitor, id} = Session.start(owner, opts)
    ref = Process.monitor(monitor)
    {:ok, session} = SessionRegistry.lookup(instance, id)
    FakeProvider.emit(:sys.get_state(session).provider_ref, %Events.UserTranscript{text: "Last words", final?: false})
    :sys.get_state(session)
    assert %{pending_user: "Last words"} = :sys.get_state(monitor)
    send(owner, :stop)
    receive_barrier({:delivered, ^id, [%{role: "user", text: "Last words"}], :user_end})
    receive_barrier({:DOWN, ^ref, :process, ^monitor, :normal})
  end

  test "ending a real session queues its transcript in the Executor journal", %{opts: opts, instance: instance} do
    :ok = Aiur.ExecutorEvents.subscribe("executor.voice.session_ended")
    {:ok, monitor, id} = Session.start(self(), Keyword.delete(opts, :deliver))
    ref = Process.monitor(monitor)
    {:ok, session} = SessionRegistry.lookup(instance, id)
    FakeProvider.emit(:sys.get_state(session).provider_ref, %Events.UserTranscript{text: "Review the release", final?: true})
    receive_barrier({:executor_voice, %Events.UserTranscript{final?: true}})
    Session.stop(monitor)
    receive_barrier({:executor_voice, {:receipt, %{id: event_id, at: at, status: "queued"}}})
    receive_barrier({:DOWN, ^ref, :process, ^monitor, :normal})
    assert {:ok, events} = Aiur.ExecutorEvents.replay(["executor.voice.session_ended"], 0)
    event = Enum.find(events, &(&1["id"] == event_id))
    assert event["session_id"] == id
    assert event["ended_at"] == at
    assert event["transcript"] == [%{"role" => "user", "text" => "Review the release"}]
    assert event["summary"] == %{"status" => "unstructured"}
  end

  test "validated summary keeps categories separate through tool result and session handoff", %{opts: opts, instance: instance} do
    :ok = Aiur.ExecutorEvents.subscribe("executor.voice.session_ended")
    {:ok, monitor, id} = Session.start(self(), Keyword.delete(opts, :deliver))
    ref = Process.monitor(monitor)
    {:ok, session} = SessionRegistry.lookup(instance, id)
    core = :sys.get_state(session)
    summary = %{decisions: ["Ship the approved release"], open_questions: ["Who deploys?"], ideas: ["Use [redacted]"]}
    params = %{"decisions" => summary.decisions, "open_questions" => summary.open_questions, "ideas" => ["Use Bearer abcdefgh12345"]}
    FakeProvider.emit(core.provider_ref, %Events.ToolCall{call_id: "summary", name: "record_summary", params: params})
    receive_barrier({:executor_voice, {:summary_recorded, recorded_summary}})
    assert recorded_summary == summary
    FakeProvider.emit(core.provider_ref, %Events.ToolCall{call_id: "invalid-summary", name: "record_summary", params: %{}})
    receive_barrier({:fake_provider, :tool_result, "invalid-summary", %{is_error: is_error}})
    assert is_error
    Session.stop(monitor)
    receive_barrier({:executor_voice, {:receipt, %{id: event_id, summary_status: summary_status}}})
    assert summary_status == "structured"
    receive_barrier({:DOWN, ^ref, :process, ^monitor, :normal})
    assert {:ok, events} = Aiur.ExecutorEvents.replay(["executor.voice.session_ended"], 0)
    event = Enum.find(events, &(&1["id"] == event_id))
    assert event["summary"] == %{"status" => "structured", "decisions" => summary.decisions, "open_questions" => summary.open_questions, "ideas" => summary.ideas}
    assert event["untrusted_fields"] == ["transcript", "summary"]
    assert {:ok, records, _meta} = TranscriptStore.read(Path.dirname(core.store.path), id)
    call = Enum.find(records, &(&1["type"] == "tool_call" and &1["call_id"] == "summary"))
    assert call["params"]["ideas"] == ["Use [redacted]"]
    refute Jason.encode!(event) =~ "abcdefgh12345"
  end
end
