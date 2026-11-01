defmodule VoiceConverse.SideQueryTest do
  use ExUnit.Case, async: false
  alias VoiceConverse.{Config, Events, SessionRegistry, TranscriptStore}
  alias VoiceConverse.Testing.{FakeProvider, StaticCredentials}

  setup do
    root = Path.join(System.tmp_dir!(), "voice_side_query_#{System.unique_integer([:positive])}")
    name = Module.concat([VoiceConverse, "SideQueryTest#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    StaticCredentials.put(%{fake: "test-secret"})
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)
    %{root: root, name: name}
  end

  test "fork options keep the recipient alive, serialize the session and bound execution", ctx do
    {id, session, provider} = start!(ctx, :never, %{fork: :native})
    history(provider, "one")
    assert_receive {:consult_fork, text, _ref, opts}, 1_000
    assert text =~ "Do not change files."
    assert opts[:reply_to] == session
    assert opts[:lock_key] == id
    assert opts[:timeout_ms] == 60_000
  end

  for {mode, prefix} <- [
        native: "Here is what the agent's notes say: ",
        history_copy: "Here is what the agent's notes say: ",
        replay: "The agent's summary says: "
      ] do
    test "#{mode} replies persist fork identity and cost", ctx do
      mode = unquote(mode)
      {id, session, provider} = start!(ctx, :never, %{fork: mode})
      history(provider, "one")
      assert_receive {:consult_fork, _, ref, _}, 1_000
      send(session, {:fork_answer, ref, "Prior constraint", mode, %{session_id: "child-id", cost_usd: 0.012}})
      prefix = unquote(prefix)
      _ = :sys.get_state(session)
      assert {:send_context, prefix <> "Prior constraint"} in FakeProvider.calls(provider)
      assert {:announce, prefix <> "Prior constraint", [when: :idle]} in FakeProvider.calls(provider)
      assert :sys.get_state(session).consult == nil
      assert {:ok, records, _} = TranscriptStore.read(ctx.root, id)

      assert [%{"text" => "Prior constraint", "fork_id" => "child-id", "cost" => 0.012, "fork_mode" => stored_mode}] =
               Enum.filter(records, &(&1["type"] == "side_query"))

      assert stored_mode == to_string(mode)
    end
  end

  test "legacy replies leave unavailable identity and cost unknown", ctx do
    {id, session, provider} = start!(ctx, :never, %{fork: :native})
    history(provider, "one")
    assert_receive {:consult_fork, _, ref, _}, 1_000
    send(session, {:fork_answer, ref, "Legacy answer"})

    _ = :sys.get_state(session)
    assert {:send_context, "Here is what the agent's notes say: Legacy answer"} in FakeProvider.calls(provider)

    assert {:ok, records, _} = TranscriptStore.read(ctx.root, id)
    assert [%{"fork_id" => nil, "cost" => nil}] = Enum.filter(records, &(&1["type"] == "side_query"))
  end

  test "adapter failure queues a checkpoint immediately and ignores late replies", ctx do
    {_id, session, provider} = start!(ctx, :never, %{fork: :native})
    history(provider, "one")
    assert_receive {:consult_fork, _, {:fork, draft_id} = ref, _}, 1_000
    send(session, {:fork_failed, ref, :timeout})
    assert_receive {:consult_ask, _, ^draft_id, opts}, 1_000
    assert opts[:delivery_policy] == :checkpoint
    send(session, {:fork_answer, ref, "Late", :native, %{}})
    _ = :sys.get_state(session)

    refute Enum.any?(
             FakeProvider.calls(provider),
             &match?({:send_context, "Here is what the agent's notes say: Late"}, &1)
           )
  end

  test "startup failure explains checkpoint fallback", ctx do
    {_id, session, provider} = start!(ctx, :never, %{fork: :native, fork_error: true})
    history(provider, "one")
    assert_receive {:consult_ask, _, _, _}, 1_000

    _ = :sys.get_state(session)

    assert {:send_context, "The side question could not start; asking the agent instead."} in FakeProvider.calls(
             provider
           )
  end

  test "replay disclosure occurs once per session", ctx do
    {_id, session, provider} = start!(ctx, :never, %{fork: :replay})

    for call <- ["one", "two"] do
      history(provider, call)
      assert_receive {:consult_fork, _, ref, _}, 1_000
      send(session, {:fork_answer, ref, call, :replay, %{}})
      prefix = if call == "one", do: "The agent's summary says: ", else: "Here is what the agent's notes say: "
      _ = :sys.get_state(session)
      assert {:send_context, prefix <> call} in FakeProvider.calls(provider)
    end
  end

  defp history(provider, call_id),
    do:
      FakeProvider.emit(provider, %Events.ToolCall{
        call_id: call_id,
        name: "ask_agent",
        params: %{"question" => "Why?", "question_type" => "history"}
      })

  defp start!(ctx, policy, target_opts) do
    {:ok, config} =
      Config.new(
        name: ctx.name,
        transcript_root: ctx.root,
        credentials: StaticCredentials,
        briefing_source: VoiceConverse.Testing.FakeBriefingSource,
        agent_channel: SideQueryTestChannel,
        provider: {FakeProvider, []},
        llm: "test",
        cloud_disclosure_accepted: true,
        ask_requires_confirm: policy
      )

    start_supervised!(VoiceConverse.child_spec(config))
    owner = self()

    schedule = fn delay, message ->
      send(owner, {:scheduled, delay, message})
      make_ref()
    end

    {:ok, id} =
      VoiceConverse.start_session(ctx.name, Map.merge(%{id: "target", test_pid: self()}, target_opts),
        client: self(),
        schedule_after: schedule,
        provider: {FakeProvider, [call_observer: self(), script: [%Events.ProviderConversationId{id: "provider"}]]}
      )

    assert_receive {:voice_conversation_state, ^id, :listening}, 1_000
    {:ok, session} = SessionRegistry.lookup(ctx.name, id)
    {id, session, :sys.get_state(session).provider_ref}
  end
end

defmodule SideQueryTestChannel do
  @behaviour VoiceConverse.Ports.AgentChannel
  def ask(target, text, ref, opts) do
    send(target.test_pid, {:consult_ask, text, ref, opts})
    {:ok, {:delivery, ref}}
  end

  defdelegate instruct(target, text, ref, opts), to: VoiceConverse.Testing.FakeAgentChannel

  def fork_query(target, text, opts) do
    ref = {:fork, opts[:ref]}
    send(target.test_pid, {:consult_fork, text, ref, opts})
    if target[:fork_error], do: {:error, :missing_session}, else: {:ok, ref}
  end

  def subscribe(_target, _pid), do: :ok

  def capabilities(target),
    do: %{
      fork: Map.get(target, :fork, :none),
      listener_mode: Map.get(target, :listener_mode, :sync),
      ask: Map.get(target, :ask_available, true)
    }
end
