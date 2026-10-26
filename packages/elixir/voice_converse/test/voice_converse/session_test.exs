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
    {:ok, id} = start!(name)
    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}

    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)
    :ok = FakeProvider.emit(:sys.get_state(session).provider_ref, %Events.UserTranscript{text: "hello", final?: true})

    assert_receive {:voice_conversation, ^id, %Events.UserTranscript{final?: true}}
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    assert Enum.any?(records, &(&1["type"] == "user_turn" and &1["text"] == "hello"))
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

  test "a provider quota error ends with provider_quota", %{root: root, name: name} do
    config = config!(root, name)
    {:ok, _pid} = Supervisor.start_link([VoiceConverse.child_spec(config)], strategy: :one_for_one)
    {:ok, id} = start!(name)
    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}

    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)
    :ok = FakeProvider.emit(:sys.get_state(session).provider_ref, Events.Error.new(:provider_quota, "quota"))

    assert_receive {:voice_conversation, ^id, {:ended, :provider_quota}}
    assert {:ok, records, _meta} = TranscriptStore.read(root, id)
    assert Enum.any?(records, &(&1["type"] == "session_ended" and &1["reason"] == "provider_quota"))
  end

  defp start!(name) do
    VoiceConverse.start_session(name, %{id: "target"},
      client: self(),
      provider: {FakeProvider, [script: [%Events.ProviderConversationId{id: "provider-session"}]]}
    )
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
