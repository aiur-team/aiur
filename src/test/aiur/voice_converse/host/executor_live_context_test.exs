defmodule Aiur.VoiceConverse.Host.ExecutorLiveContextTest do
  use Aiur.TestSupport

  alias Aiur.VoiceConverse.Host.{AgentChannel, BriefingSource, CommandSource}
  alias VoiceConverse.{Briefing, Config, Events, SessionRegistry, TranscriptStore}
  alias VoiceConverse.Testing.{FakeProvider, StaticCredentials}

  test "Executor host subscriptions do not report an inapplicable channel as unavailable or refresh on tools" do
    root = Aiur.TestSupport.tmp_root!("executor-live-context")
    name = Module.concat(__MODULE__, "Instance#{System.unique_integer([:positive])}")
    credentials_key = {StaticCredentials, :secrets}
    previous = :persistent_term.get(credentials_key, :missing)

    on_exit(fn ->
      if previous == :missing, do: :persistent_term.erase(credentials_key), else: :persistent_term.put(credentials_key, previous)
    end)

    StaticCredentials.put(%{fake: "test"})

    {:ok, config} =
      Config.new(
        name: name,
        transcript_root: root,
        credentials: StaticCredentials,
        briefing_source: BriefingSource,
        agent_channel: AgentChannel,
        command_source: CommandSource,
        provider: FakeProvider,
        llm: "test",
        cloud_disclosure_accepted: true
      )

    start_supervised!(VoiceConverse.child_spec(config))

    {:ok, id} =
      VoiceConverse.start_session(name, :executor,
        client: self(),
        provider: {FakeProvider, [script: [%Events.ProviderConversationId{id: "executor-live"}], call_observer: self()]}
      )

    assert_receive {:voice_conversation_state, ^id, :listening}, 1_000
    {:ok, session} = SessionRegistry.lookup(name, id)
    state = :sys.get_state(session)
    refute state.live_context.fallback?
    refute state.context =~ "Live updates unavailable"
    assert {:ok, records, _} = TranscriptStore.read(root, id)
    refute Enum.any?(records, &String.contains?(Map.get(&1, "text", ""), "Live updates unavailable"))

    # A pushed source update must survive an unrelated tool call. A fallback read
    # would replace it with the host's prototype snapshot instead.
    card = %Briefing{summary: %{value: "Pushed Executor status", observed_at: DateTime.utc_now(), max_age_s: 30}}
    send(session, {:briefing, card})
    assert :sys.get_state(session).live_context.briefing == card
    mfa = {BriefingSource, :brief, 1}
    {:match_spec, previous_trace} = :erlang.trace_info(mfa, :match_spec)
    :erlang.trace_pattern(mfa, true, [:local])
    on_exit(fn -> :erlang.trace_pattern(mfa, previous_trace, [:local]) end)
    :erlang.trace(session, true, [:call, :set_on_spawn, {:tracer, self()}])
    FakeProvider.emit(state.provider_ref, %Events.ToolCall{call_id: "probe", name: "unknown", params: %{}})
    assert_receive {:fake_provider, :tool_result, "probe", _}, 1_000
    assert :sys.get_state(session).live_context.briefing == card
    delivered = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivered}, 1_000
    refute_received {:trace, _, :call, {BriefingSource, :brief, [:executor]}}
    :erlang.trace(session, false, [:call, :set_on_spawn])
  end
end
