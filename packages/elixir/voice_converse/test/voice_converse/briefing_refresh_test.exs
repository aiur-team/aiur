defmodule VoiceConverse.BriefingRefreshTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Briefing, Config, Events, TranscriptStore}
  alias VoiceConverse.Testing.{FakeBriefingSource, FakeProvider, StaticCredentials}

  setup do
    root =
      Path.join(System.tmp_dir!(), "voice_converse_refresh_#{System.unique_integer([:positive])}")

    name = Module.concat([VoiceConverse, "BriefingRefresh#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    StaticCredentials.put(%{fake: "test-secret"})
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)
    config = config!(root, name)
    start_supervised!(VoiceConverse.child_spec(config))
    %{root: root, name: name}
  end

  test "host refresh sends changed lines once and stores the context record", %{
    root: root,
    name: name
  } do
    target = target(self(), "First")
    {:ok, id} = start(name, target)
    assert_receive {:fake_briefing_source, :subscribe, _pid}
    refute_received {:fake_briefing_source, :subscribe, _pid}
    await_listening(id)
    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)
    provider = :sys.get_state(session).provider_ref
    update(target, "Updated")

    assert :ok = VoiceConverse.refresh_briefing(name, id)
    assert FakeProvider.calls(provider) == [{:send_context, "Summary: Updated"}]
    assert :ok = VoiceConverse.refresh_briefing(name, id)
    assert FakeProvider.calls(provider) == [{:send_context, "Summary: Updated"}]

    assert {:ok, records, _meta} = TranscriptStore.read(root, id)

    [refresh] =
      Enum.filter(
        records,
        &(&1["type"] == "context" and &1["source"] == "briefing" and
            &1["text"] == "Summary: Updated")
      )

    assert refresh["text"] == "Summary: Updated"
  end

  test "refresh while reconnecting is sent after the provider returns", %{name: name} do
    target = target(self(), "First")
    {:ok, id} = start(name, target)
    assert_receive {:fake_briefing_source, :subscribe, _pid}
    refute_received {:fake_briefing_source, :subscribe, _pid}
    await_listening(id)
    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)
    first_provider = :sys.get_state(session).provider_ref
    :ok = FakeProvider.emit(first_provider, %Events.Closed{reason: :unexpected})
    assert_receive {:voice_conversation_state, ^id, :reconnecting}
    update(target, "During reconnect")

    assert :ok = VoiceConverse.refresh_briefing(name, id)
    assert_eventually(fn -> :sys.get_state(session).provider_ref not in [nil, first_provider] end)
    second_provider = :sys.get_state(session).provider_ref

    assert_eventually(fn ->
      FakeProvider.calls(second_provider) == [{:send_context, "Summary: During reconnect"}]
    end)
  end

  test "oversize briefing diffs stay within budget and on grapheme boundaries", %{root: root} do
    name = Module.concat([VoiceConverse, "BriefingBudget#{System.unique_integer([:positive])}"])
    config = config!(root, name, limits: %{briefing_token_budget: 3})
    start_supervised!(VoiceConverse.child_spec(config))
    target = target(self(), "First")
    {:ok, id} = start(name, target)
    assert_receive {:fake_briefing_source, :subscribe, _pid}
    refute_received {:fake_briefing_source, :subscribe, _pid}
    await_listening(id)
    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)
    provider = :sys.get_state(session).provider_ref
    update(target, "é🙂 beyond budget")

    assert :ok = VoiceConverse.refresh_briefing(name, id)

    assert [{:send_context, text}] = FakeProvider.calls(provider)
    assert String.valid?(text)
    assert String.ends_with?(text, "é")
    assert div(byte_size(text), 4) <= 3
  end

  test "refresh redacts secrets from provider context and transcript", %{root: root} do
    name = Module.concat([VoiceConverse, "BriefingRedaction#{System.unique_integer([:positive])}"])

    redactor = fn text -> String.replace(text, "test-secret", "[REDACTED]") end
    config = config!(root, name, redactor: redactor)
    start_supervised!(VoiceConverse.child_spec(config))
    target = target(self(), "First")
    {:ok, id} = start(name, target)
    assert_receive {:fake_briefing_source, :subscribe, _pid}
    refute_received {:fake_briefing_source, :subscribe, _pid}
    await_listening(id)
    {:ok, session} = VoiceConverse.SessionRegistry.lookup(name, id)
    provider = :sys.get_state(session).provider_ref
    update(target, "contains test-secret")

    assert :ok = VoiceConverse.refresh_briefing(name, id)
    assert [{:send_context, "Summary: contains [REDACTED]"}] = FakeProvider.calls(provider)

    assert {:ok, records, _meta} = TranscriptStore.read(root, id)

    refresh =
      Enum.find(records, fn record ->
        record["type"] == "context" and record["source"] == "briefing" and
          String.contains?(record["text"], "Summary: contains")
      end)

    assert refresh["text"] == "Summary: contains [REDACTED]"
    refute String.contains?(refresh["text"], "test-secret")
  end

  defp start(name, target) do
    VoiceConverse.start_session(name, target,
      client: self(),
      provider: {FakeProvider, [script: [%Events.ProviderConversationId{id: "provider-session"}]]}
    )
  end

  defp target(observer, summary) do
    agent = start_supervised!({Agent, fn -> %Briefing{summary: %{value: summary}} end})
    %{id: "target", briefing_agent: agent, observer: observer, subscribe: true}
  end

  defp update(%{briefing_agent: agent}, summary),
    do: Agent.update(agent, &%{&1 | summary: %{value: summary}})

  defp await_listening(id) do
    assert_receive {:voice_conversation_state, ^id, :connecting}
    assert_receive {:voice_conversation_state, ^id, :listening}
  end

  defp config!(root, name, opts \\ []) do
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
        ] ++ opts
      )

    config
  end

  defp assert_eventually(fun, attempts \\ 40) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(25)
        assert_eventually(fun, attempts - 1)
    end
  end
end
