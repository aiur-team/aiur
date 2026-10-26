defmodule VoiceConverse.SessionTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Config, Events, TranscriptStore}
  alias VoiceConverse.Testing.{FakeBriefingSource, FakeProvider, StaticCredentials}

  setup do
    root = Path.join(System.tmp_dir!(), "voice_converse_session_#{System.unique_integer([:positive])}")
    name = Module.concat([VoiceConverse, "SessionTest#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    StaticCredentials.put(%{fake: "test-secret"})
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)
    %{root: root, name: name}
  end

  test "a session cannot start until the operator chooses an llm", %{root: root, name: name} do
    config = config!(root, name, llm: nil)
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)

    assert {:error, :llm} = VoiceConverse.start_session(name, %{id: "target"}, [])
  end

  test "a session cannot start until the operator accepts the cloud disclosure", %{root: root, name: name} do
    config = config!(root, name, cloud_disclosure_accepted: nil)
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)

    assert {:error, :cloud_disclosure_accepted} = VoiceConverse.start_session(name, %{id: "target"}, [])
  end

  test "a final user turn is durable before a subscriber receives it", %{root: root, name: name} do
    config = config!(root, name)
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)
    test_pid = self()

    event_broadcast = fn subscribers, id, event ->
      if match?(%Events.UserTranscript{final?: true}, event) do
        send(test_pid, {:final_turn_ready_to_broadcast, id})

        receive do
          :release_final_turn_broadcast -> :ok
        end
      end

      Enum.each(Map.keys(subscribers), &send(&1, {:voice_conversation, id, event}))
    end

    {:ok, id} = start!(name, event_broadcast: event_broadcast)
    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}

    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)
    :ok = FakeProvider.emit(:sys.get_state(session).provider_ref, %Events.UserTranscript{text: "hello", final?: true})

    assert_receive {:final_turn_ready_to_broadcast, ^id}
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    assert Enum.any?(records, &(&1["type"] == "user_turn" and &1["text"] == "hello"))
    send(session, :release_final_turn_broadcast)
    assert_receive {:voice_conversation, ^id, %Events.UserTranscript{final?: true}}
  end

  test "audio and partial text are broadcast but never stored", %{root: root, name: name} do
    config = config!(root, name)
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)
    {:ok, id} = start!(name)
    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}

    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)
    provider = :sys.get_state(session).provider_ref
    :ok = FakeProvider.emit(provider, %Events.UserTranscript{text: "partial secret", final?: false})
    :ok = FakeProvider.emit(provider, %Events.AgentText{turn_id: "a", text: "partial reply", final?: false})
    :ok = FakeProvider.emit(provider, %Events.AgentAudio{turn_id: "a", format: :pcm_16000, data_b64: "c2VjcmV0"})

    assert_receive {:voice_conversation, ^id, %Events.UserTranscript{final?: false}}
    assert_receive {:voice_conversation, ^id, %Events.AgentText{final?: false}}
    assert_receive {:voice_conversation, ^id, %Events.AgentAudio{}}
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)

    refute Enum.any?(records, fn record ->
             record["text"] in ["partial secret", "partial reply"] or Map.has_key?(record, "data_b64")
           end)
  end

  test "a zero daily cap refuses before the provider opens", %{root: root, name: name} do
    config = config!(root, name, limits: %{daily_minutes_cap: 0})
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)

    assert {:error, :cost_cap} = VoiceConverse.start_session(name, %{id: "target"}, [])
  end

  test "a daily cap reached during a session ends at the next final turn", %{root: root, name: name} do
    config = config!(root, name, limits: %{daily_minutes_cap: 1})
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)
    started_at = ~U[2026-10-25 12:00:00Z]
    clock = advancing_clock(started_at, DateTime.add(started_at, 61, :second))
    {:ok, id} = start!(name, clock: clock)
    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}

    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)

    :ok =
      FakeProvider.emit(:sys.get_state(session).provider_ref, %Events.UserTranscript{text: "one more", final?: true})

    assert_receive {:voice_conversation, ^id, %Events.UserTranscript{final?: true}}
    assert_receive {:voice_conversation, ^id, {:ended, :cost_cap}}, 1_000
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    assert Enum.any?(records, &(&1["type"] == "user_turn" and &1["text"] == "one more"))
  end

  test "a failed preflight never opens the provider", %{root: root, name: name} do
    config = config!(root, name)
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)

    assert {:error, :privacy_preflight_failed} =
             VoiceConverse.start_session(name, %{id: "target"},
               provider: {FakeProvider, [observer: self(), preflight_error: Events.Error.new(:provider_error, "no")]}
             )

    assert_receive {:fake_provider, :preflight}
    refute_receive {:fake_provider, :open}
  end

  test "provider id is durable before the listening state", %{root: root, name: name} do
    config = config!(root, name)
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)
    {:ok, id} = start!(name)

    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)

    assert Enum.any?(records, fn record ->
             record["type"] == "provider_conversation" and record["id"] == "provider-session"
           end)
  end

  test "idle and maximum-duration timers end the session with their distinct reasons", %{root: root, name: name} do
    config = config!(root, name, limits: %{max_sessions: 2})
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)
    {:ok, idle_id} = start!(name)
    assert_receive {:voice_conversation_state, ^idle_id, :connecting}
    assert_receive {:voice_conversation_state, ^idle_id, :listening}
    {:ok, idle_session} = VoiceConverse.SessionRegistry.lookup(name, idle_id)
    send(idle_session, {:idle_timeout, :sys.get_state(idle_session).idle_token})
    assert_receive {:voice_conversation, ^idle_id, {:ended, :idle_timeout}}, 1_000

    {:ok, max_id} = start!(name)
    assert_receive {:voice_conversation_state, ^max_id, :connecting}
    assert_receive {:voice_conversation_state, ^max_id, :listening}
    {:ok, max_session} = VoiceConverse.SessionRegistry.lookup(name, max_id)
    send(max_session, :max_duration)
    assert_receive {:voice_conversation, ^max_id, {:ended, :max_duration}}, 1_000
  end

  test "state transitions follow the session state table", %{root: root, name: name} do
    config = config!(root, name)
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)
    {:ok, id} = start!(name)
    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}

    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)
    provider = :sys.get_state(session).provider_ref
    :ok = FakeProvider.emit(provider, %Events.UserTranscript{text: "question", final?: true})
    assert_receive {:voice_conversation_state, ^id, :thinking}
    :ok = FakeProvider.emit(provider, %Events.AgentAudio{turn_id: "a", format: :pcm_16000, data_b64: "AA=="})
    assert_receive {:voice_conversation_state, ^id, :speaking}
    :ok = FakeProvider.emit(provider, %Events.Interruption{turn_id: "a"})
    assert_receive {:voice_conversation_state, ^id, :listening}
  end

  test "an unexpected close reconnects once then ends with provider_error", %{root: root, name: name} do
    config = config!(root, name)
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)
    {:ok, id} = start!(name)
    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}

    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)
    :ok = FakeProvider.emit(:sys.get_state(session).provider_ref, %Events.Closed{reason: :unexpected})
    assert_receive {:voice_conversation_state, ^id, :reconnecting}
    assert_receive {:voice_conversation_state, ^id, :listening}

    :ok = FakeProvider.emit(:sys.get_state(session).provider_ref, %Events.Closed{reason: :unexpected})
    assert_receive {:voice_conversation_state, ^id, :error}
    assert_receive {:voice_conversation, ^id, {:ended, :provider_error}}, 1_000
  end

  test "a provider quota error ends with provider_quota", %{root: root, name: name} do
    config = config!(root, name)
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)
    {:ok, id} = start!(name)
    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}

    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)
    :ok = FakeProvider.emit(:sys.get_state(session).provider_ref, Events.Error.new(:provider_quota, "quota"))

    assert_receive {:voice_conversation, ^id, {:ended, :provider_quota}}, 1_000
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    assert Enum.any?(records, &(&1["type"] == "session_ended" and &1["reason"] == "provider_quota"))
  end

  defp start!(name, opts \\ []) do
    VoiceConverse.start_session(
      name,
      %{id: "target"},
      Keyword.merge(
        [client: self(), provider: {FakeProvider, [script: [%Events.ProviderConversationId{id: "provider-session"}]]}],
        opts
      )
    )
  end

  defp advancing_clock(started_at, later) do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    fn ->
      Agent.get_and_update(clock, fn
        0 -> {started_at, 1}
        count -> {later, count + 1}
      end)
    end
  end

  defp config!(root, name, overrides \\ []) do
    {:ok, config} =
      Config.new(
        [
          name: name,
          transcript_root: root,
          credentials: StaticCredentials,
          briefing_source: FakeBriefingSource,
          provider: {FakeProvider, []},
          llm: "test-model",
          cloud_disclosure_accepted: true
        ]
        |> Keyword.merge(overrides)
      )

    config
  end
end
