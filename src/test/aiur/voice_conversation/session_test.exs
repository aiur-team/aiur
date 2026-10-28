defmodule Aiur.VoiceConversation.SessionTest do
  use Aiur.TestSupport

  alias Aiur.VoiceConversation.Session
  alias VoiceConverse.{Config, Events, SessionRegistry}
  alias VoiceConverse.Testing.{FakeBriefingSource, FakeProvider, StaticCredentials}

  setup do
    root = Aiur.TestSupport.tmp_root!("executor-voice-session")
    instance = Module.concat(__MODULE__, "Instance#{System.unique_integer([:positive])}")
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
    receive_barrier({:executor_voice, %Events.AgentText{}})
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
      spawn(fn ->
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

  test "handoff failure remains visible instead of producing a receipt", %{opts: opts} do
    opts = Keyword.put(opts, :deliver, fn _, _, _ -> {:error, :disk_full} end)
    {:ok, monitor, _id} = Session.start(self(), opts)
    ref = Process.monitor(monitor)
    Session.stop(monitor)
    receive_barrier({:DOWN, ^ref, :process, ^monitor, :normal})
    receive_barrier({:executor_voice, {:handoff_failed, :delivery_failed}})
    refute_received {:executor_voice, {:receipt, _}}
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
    assert event["summary"] == "1 transcript turns: user: Review the release"
  end
end
