defmodule VoiceConverse.ConsultFailureTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Config, Events, SessionRegistry}
  alias VoiceConverse.Testing.{FakeAgentChannel, FakeBriefingSource, FakeProvider, StaticCredentials}

  test "a failed transcript write cannot announce an answer" do
    root = Path.join(System.tmp_dir!(), "voice_consult_failure_#{System.unique_integer([:positive])}")
    name = Module.concat([VoiceConverse, "ConsultFailure#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)
    StaticCredentials.put(%{fake: "test-secret"})

    {:ok, config} =
      Config.new(
        name: name,
        transcript_root: root,
        credentials: StaticCredentials,
        briefing_source: FakeBriefingSource,
        agent_channel: FakeAgentChannel,
        provider: {FakeProvider, []},
        llm: "test",
        cloud_disclosure_accepted: true,
        ask_requires_confirm: :never
      )

    start_supervised!(VoiceConverse.child_spec(config))

    {:ok, id} =
      VoiceConverse.start_session(name, %{id: "target", test_pid: self()},
        client: self(),
        provider: {FakeProvider, [script: [%Events.ProviderConversationId{id: "provider"}]]}
      )

    assert_receive {:voice_conversation_state, ^id, :listening}, 1_000
    {:ok, session} = SessionRegistry.lookup(name, id)
    provider = :sys.get_state(session).provider_ref
    FakeProvider.emit(provider, %Events.ToolCall{call_id: "one", name: "ask_agent", params: %{"question" => "Why?"}})
    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: draft_id, kind: "consult"}}}, 1_000
    assert_receive {:fake_channel, {:ask, _, ^draft_id}}, 1_000
    delivery = :sys.get_state(session).consult.delivery_id
    send(session, {:receipt, delivery, :delivered})
    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: ^draft_id, status: "delivered"}}}, 1_000
    monitor = Process.monitor(session)
    :sys.replace_state(session, fn state -> put_in(state.store.datasync, fn _ -> {:error, :eio} end) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(session, {:agent_reply, delivery, "Private answer"})
        assert_receive {:DOWN, ^monitor, :process, ^session, _}, 1_000
      end)

    refute log =~ "Private answer"
    refute {:send_context, "The agent answered: Private answer"} in FakeProvider.calls(provider)
  end
end
