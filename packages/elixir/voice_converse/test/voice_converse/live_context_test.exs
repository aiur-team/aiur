defmodule VoiceConverse.LiveContextTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Briefing, Config, Drafts, Events, LiveContext, SessionRegistry, TranscriptStore}
  alias VoiceConverse.Testing.{FakeBriefingSource, FakeProvider, StaticCredentials}

  defmodule Source do
    defdelegate describe_target(t), to: FakeBriefingSource
    def brief(%{briefing_agent: agent}), do: {:ok, Agent.get(agent, & &1)}
    def brief(t), do: FakeBriefingSource.brief(t)
    defdelegate alive?(t), to: FakeBriefingSource
    defdelegate sections(t), to: FakeBriefingSource

    def subscribe(target, pid) do
      send(target.test_pid, {:subscribed, pid})

      if updated = target[:after_subscribe] do
        Agent.update(target.briefing_agent, fn _ -> updated end)
        send(pid, {:briefing, updated})
      end

      :ok
    end
  end

  defmodule Provider do
    def send_context({observer, store}, text) do
      {:ok, records, _} = TranscriptStore.read(Path.dirname(store.path), store.conversation_id)
      send(observer, {:sent, text, records})
      :ok
    end

    def announce({observer, _store}, text, opts), do: send(observer, {:announced, text, opts})
  end

  setup do
    root = Path.join(System.tmp_dir!(), "live_context_#{System.unique_integer([:positive])}")
    name = Module.concat(__MODULE__, "Instance#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    StaticCredentials.put(%{fake: "secret"})

    {:ok, config} =
      Config.new(
        name: name,
        transcript_root: root,
        credentials: StaticCredentials,
        briefing_source: Source,
        provider: {FakeProvider, [script: [%Events.ProviderConversationId{id: "provider-live"}]]},
        llm: "test",
        cloud_disclosure_accepted: true,
        redactor: &String.replace(&1, "secret", "[REDACTED]")
      )

    start_supervised!({VoiceConverse, config})
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)
    %{root: root, name: name, config: config}
  end

  test "session subscribes and sends changed briefing lines without changing speaking state", ctx do
    {:ok, id} = VoiceConverse.start_session(ctx.name, %{test_pid: self()}, client: self())
    assert_receive {:subscribed, session}, 1_000
    assert_receive {:voice_conversation_state, ^id, :connecting}, 1_000
    assert_receive {:voice_conversation_state, ^id, :listening}, 1_000
    assert {:ok, ^session} = SessionRegistry.lookup(ctx.name, id)
    provider = :sys.get_state(session).provider_ref
    FakeProvider.emit(provider, %Events.AgentText{turn_id: "a", text: "speaking", final?: false})
    :sys.get_state(session)
    send(session, {:briefing, %Briefing{summary: field("new work")}})
    state = :sys.get_state(session)
    assert state.state == :speaking
    assert FakeProvider.calls(provider) == [{:send_context, "Summary: new work"}]
    send(session, {:briefing, %Briefing{version: 2, summary: field("new work")}})
    :sys.get_state(session)
    assert FakeProvider.calls(provider) == [{:send_context, "Summary: new work"}]
  end

  test "a change between opening context and subscription is compared with the opening snapshot", ctx do
    card = %Briefing{summary: field("old snapshot")}
    agent = start_supervised!({Agent, fn -> card end})
    target = %{test_pid: self(), briefing_agent: agent, after_subscribe: %Briefing{summary: field("new snapshot")}}
    {:ok, id} = VoiceConverse.start_session(ctx.name, target, client: self())
    assert_receive {:voice_conversation_state, ^id, :listening}, 1_000
    {:ok, session} = SessionRegistry.lookup(ctx.name, id)
    state = :sys.get_state(session)
    assert state.context =~ "old snapshot"
    assert FakeProvider.calls(state.provider_ref) == [{:send_context, "Summary: new snapshot"}]
  end

  test "each redacted event is durable before provider delivery, bursts coalesce and notes announce at idle", ctx do
    {state, clock} = state(ctx)
    {:noreply, state} = LiveContext.handle_info({:context_update, "New Command: secret?", []}, state)
    assert_receive {:sent, "New Command: [REDACTED]?", records}, 1_000
    assert List.last(records)["text"] == "New Command: [REDACTED]?"
    {:noreply, state} = LiveContext.handle_info({:context_update, "phase done", []}, state)
    {:noreply, state} = LiveContext.handle_info({:context_update, "refreshed secret", [announce: true]}, state)
    refute_receive {:sent, _, _}, 100
    assert_receive {:scheduled, 5_000, {:live_context_flush, token}}, 1_000
    assert {:ok, records, _} = TranscriptStore.read(ctx.root, "vc_AAAAAAAAAAAAAAAAAAAAAA")

    assert Enum.map(records, & &1["text"]) |> Enum.take(-3) == [
             "New Command: [REDACTED]?",
             "phase done",
             "refreshed [REDACTED]"
           ]

    Agent.update(clock, &DateTime.add(&1, 5, :second))
    {:noreply, state} = LiveContext.handle_info({:live_context_flush, token}, state)
    assert_receive {:sent, "phase done\nrefreshed [REDACTED]", _}, 1_000
    assert_receive {:announced, "refreshed [REDACTED]", [when: :idle]}, 1_000
    assert state.live_context.pending == []
  end

  test "resolved Command stales proposed instructions durably but preserves sent drafts", ctx do
    {state, _clock} = state(ctx)
    {:ok, proposed, drafts} = Drafts.propose_instruction(state.drafts, "use old choice", target: %{id: "worker"})
    {:ok, sent, drafts} = Drafts.propose_instruction(drafts, "already sent")
    {:ok, _, drafts} = Drafts.confirm(drafts, sent.draft_id, %{source: :client_socket, principal: :operator}, [])
    {:ok, _, drafts} = Drafts.transition(drafts, sent.draft_id, :sent)
    {:noreply, state} = LiveContext.handle_info({:command_resolved, "cmd1"}, %{state | drafts: drafts})
    assert {:ok, %{status: :stale}} = Drafts.fetch(state.drafts, proposed.draft_id)
    assert {:ok, %{status: :sent}} = Drafts.fetch(state.drafts, sent.draft_id)
    assert_receive {:sent, "Command cmd1 resolved", records}, 1_000
    assert Enum.any?(records, &(&1["type"] == "draft" and &1["status"] == "stale"))
  end

  test "unsupported subscription records explicit gap and refreshes on tools only", ctx do
    {state, _clock} = state(ctx, FakeBriefingSource)
    assert state.live_context.fallback?
    assert state.context =~ "Live updates unavailable"
    changed = %{state.target | briefing: %Briefing{summary: field("updated")}}
    state = LiveContext.refresh(%{state | target: changed})
    assert_receive {:sent, "Summary: updated", _}, 1_000
    assert state.live_context.briefing.summary.value == "updated"
  end

  test "a lost subscription records a gap and enables tool refresh", ctx do
    {state, _clock} = state(ctx)
    refute state.live_context.fallback?
    {:noreply, state} = LiveContext.handle_info(:live_context_unavailable, state)
    assert state.live_context.fallback?
    assert_receive {:sent, "Gaps: Live updates unavailable; refresh on tool calls", records}, 1_000
    assert List.last(records)["source"] == "events"
  end

  test "reconnect defers updates and retains only ten recent milestones", ctx do
    {state, _clock} = state(ctx)
    ref = state.provider_ref

    state =
      Enum.reduce(1..12, %{state | provider_ref: nil}, fn n, state ->
        {:noreply, state} = LiveContext.handle_info({:context_update, "event #{n}", []}, state)
        state
      end)

    refute_receive {:sent, _, _}, 100
    assert state.live_context.events == Enum.map(3..12, &"event #{&1}")
    state = LiveContext.ready(%{state | provider_ref: ref})
    assert_receive {:sent, text, _}, 1_000
    assert text =~ "event 12"
    assert state.live_context.pending == []
  end

  test "target gone ends the real session with its durable reason", ctx do
    {:ok, id} = VoiceConverse.start_session(ctx.name, %{test_pid: self()}, client: self())
    assert_receive {:subscribed, session}, 1_000
    send(session, :target_gone)
    assert_receive {:voice_conversation, ^id, {:ended, :target_gone}}, 1_000
    assert {:ok, records, _} = TranscriptStore.read(ctx.root, id)
    assert Enum.any?(records, &(&1["type"] == "session_ended" and &1["reason"] == "target_gone"))
  end

  test "a failed durable append never delivers context", ctx do
    {state, _clock} = state(ctx)
    state = %{state | store: %{state.store | datasync: fn _ -> {:error, :eio} end}}
    assert_raise MatchError, fn -> LiveContext.handle_info({:context_update, "not durable", []}, state) end
    refute_receive {:sent, _, _}, 100
  end

  test "consult announcements wait for the reconnected provider", ctx do
    {state, _clock} = state(ctx)
    ref = state.provider_ref
    state = LiveContext.announce(%{state | provider_ref: nil}, "Answer arrived")
    refute_receive {:announced, _, _}, 100
    state = LiveContext.ready(%{state | provider_ref: ref})
    assert_receive {:announced, "Answer arrived", [when: :idle]}, 1_000
    assert state.live_context.announcements == []
  end

  defp state(ctx, source \\ Source) do
    {:ok, store} = TranscriptStore.start(ctx.config, "vc_AAAAAAAAAAAAAAAAAAAAAA", %{target: %{id: "worker"}})
    clock = start_supervised!({Agent, fn -> DateTime.utc_now() end})
    observer = self()

    state = %{
      config: %{ctx.config | briefing_source: source},
      target: %{test_pid: self(), briefing: %Briefing{}},
      context: "initial",
      drafts: Drafts.new(),
      subscribers: %{},
      id: "vc_AAAAAAAAAAAAAAAAAAAAAA",
      store: store,
      provider: Provider,
      provider_ref: {observer, store},
      state: :speaking,
      finishing?: false,
      finished?: false,
      clock: fn -> Agent.get(clock, & &1) end,
      event_broadcast: fn _, _, _ -> :ok end,
      schedule_after: fn delay, message ->
        send(observer, {:scheduled, delay, message})
        make_ref()
      end
    }

    {LiveContext.attach(state), clock}
  end

  defp field(text), do: %{value: text, observed_at: DateTime.utc_now(), max_age_s: 30}
end
