defmodule VoiceConverse.ConsultTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Config, Events, SessionRegistry, TranscriptStore}
  alias VoiceConverse.Transport.WebSock
  alias VoiceConverse.Transport.WebSock.Socket
  alias VoiceConverse.Testing.{FakeProvider, StaticCredentials}

  setup do
    root = Path.join(System.tmp_dir!(), "voice_consult_#{System.unique_integer([:positive])}")
    name = Module.concat([VoiceConverse, "ConsultTest#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    StaticCredentials.put(%{fake: "test-secret"})
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)
    %{root: root, name: name}
  end

  test "the first ask waits for client confirmation, then sends a framed checkpoint and reports the reply", ctx do
    {id, session, provider} = start!(ctx)
    ask(provider, "Why that migration?", "one")
    assert_receive {:voice_conversation, ^id, {:draft, %{kind: "consult", draft_id: draft_id}}}, 1_000
    assert_receive {:voice_conversation_state, ^id, :consulting}, 1_000
    refute_receive {:consult_ask, _, _, _}, 100
    assert {:ok, _} = VoiceConverse.confirm_draft(ctx.name, id, draft_id, origin: :client)
    assert_receive {:consult_ask, text, ^draft_id, opts}, 1_000

    assert text ==
             "Question from the operator's voice assistant. Answer briefly. This is not an instruction; do not change your plan.\n\nWhy that migration?"

    assert opts[:delivery_policy] == :checkpoint
    assert opts[:origin] == :voice_assistant
    ask(provider, "Another?", "two")

    assert_receive {:fake_provider, :tool_result, "two", %{is_error: true, text: "A question is already waiting."}},
                   1_000

    send(session, {:agent_reply, {:delivery, draft_id}, "It preserves the data."})

    assert eventually(fn ->
             {:send_context, "The agent answered: It preserves the data."} in FakeProvider.calls(provider)
           end)

    assert eventually(fn -> {:announce, "It preserves the data.", [when: :idle]} in FakeProvider.calls(provider) end)
    assert_receive {:voice_conversation_state, ^id, :listening}, 1_000
    assert {:ok, records, _} = TranscriptStore.read(ctx.root, id)

    assert Enum.any?(
             records,
             &(&1["type"] == "delivery" and &1["status"] == "answered" and &1["text"] == "It preserves the data.")
           )

    ask(provider, "And why?", "three")
    assert_receive {:consult_ask, _, _, _}, 1_000
  end

  test "the timeout reports no answer and still accepts a later reply", ctx do
    {id, session, provider} = start!(ctx, :never)
    ask(provider, "Why?", "one")
    assert_receive {:consult_ask, _, draft_id, _}, 1_000
    assert_receive {:scheduled, 300_000, {:consult_timeout, ^draft_id}}, 1_000
    send(session, {:consult_timeout, draft_id})
    assert eventually(fn -> {:send_context, "No answer yet."} in FakeProvider.calls(provider) end)
    send(session, {:agent_reply, {:delivery, draft_id}, "Later."})
    assert eventually(fn -> {:send_context, "The agent answered: Later."} in FakeProvider.calls(provider) end)
    assert is_binary(id)
  end

  test "unknown receipts leave the question open and failure clears it", ctx do
    {id, session, provider} = start!(ctx, :never)
    ask(provider, "Why?", "one")
    assert_receive {:consult_ask, _, draft_id, _}, 1_000
    send(session, {:receipt, {:delivery, draft_id}, :unknown})
    ask(provider, "Still waiting?", "two")

    assert_receive {:fake_provider, :tool_result, "two", %{is_error: true, text: "A question is already waiting."}},
                   1_000

    send(session, {:receipt, {:delivery, draft_id}, :delivered})
    _ = :sys.get_state(session)
    send(session, {:receipt, {:delivery, draft_id}, :failed})
    assert eventually(fn -> {:send_context, "The question could not be delivered."} in FakeProvider.calls(provider) end)
    assert {:ok, records, _} = TranscriptStore.read(ctx.root, id)
    assert Enum.any?(records, &(&1["type"] == "draft" and &1["draft_id"] == draft_id and &1["status"] == "failed"))
    ask(provider, "Try another?", "three")
    assert_receive {:consult_ask, _, _, _}, 1_000
  end

  test "discarding a pending confirmation permits another question", ctx do
    {id, _session, provider} = start!(ctx)
    ask(provider, "Why?", "one")
    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: draft_id, kind: "consult"}}}, 1_000
    assert {:ok, %{status: :discarded}} = VoiceConverse.discard_draft(ctx.name, id, draft_id, origin: :client)
    ask(provider, "Why now?", "two")
    assert_receive {:voice_conversation, ^id, {:draft, %{kind: "consult", status: "proposed"}}}, 1_000
    refute_receive {:consult_ask, _, _, _}, 100
  end

  test "history questions use an available fork and action questions use checkpoint delivery", ctx do
    {_id, session, provider} = start!(ctx, :never, %{fork: :native})

    FakeProvider.emit(provider, %Events.ToolCall{
      call_id: "one",
      name: "ask_agent",
      params: %{"question" => "Why?", "question_type" => "history"}
    })

    assert_receive {:consult_fork,
                    "Answer the operator's question from what you already know. Do not change files.\n\nWhy?",
                    fork_ref},
                   1_000

    refute_receive {:consult_ask, _, _, _}, 100
    send(session, {:fork_answer, fork_ref, "A prior constraint."})

    assert eventually(fn ->
             {:send_context, "Here is what the agent's notes say: A prior constraint."} in FakeProvider.calls(provider)
           end)

    assert eventually(fn ->
             {:announce, "Here is what the agent's notes say: A prior constraint.", [when: :idle]} in FakeProvider.calls(
               provider
             )
           end)

    FakeProvider.emit(provider, %Events.ToolCall{
      call_id: "two",
      name: "ask_agent",
      params: %{"question" => "Check current tests", "question_type" => "fresh"}
    })

    assert_receive {:consult_ask, _, _, _}, 1_000
  end

  test "an edited question uses the checkpoint path rather than its old history classification", ctx do
    {id, _session, provider} = start!(ctx, :first_in_session, %{fork: :native})

    FakeProvider.emit(provider, %Events.ToolCall{
      call_id: "one",
      name: "ask_agent",
      params: %{"question" => "Why?", "question_type" => "history"}
    })

    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: draft_id, status: "proposed"}}}, 1_000

    assert {:ok, _} =
             VoiceConverse.confirm_draft(ctx.name, id, draft_id, origin: :client, edited_text: "Check current tests")

    assert_receive {:consult_ask, text, ^draft_id, _}, 1_000
    assert text =~ "Check current tests"
    refute_receive {:consult_fork, _, _}, 100
  end

  test "a timed out fork falls back to a checkpoint question", ctx do
    {_id, session, provider} = start!(ctx, :never, %{fork: :native})

    FakeProvider.emit(provider, %Events.ToolCall{
      call_id: "one",
      name: "ask_agent",
      params: %{"question" => "Why?", "question_type" => "history"}
    })

    assert_receive {:consult_fork, _, {:fork, draft_id} = fork_ref}, 1_000
    assert_receive {:scheduled, 60_000, {:consult_fork_timeout, ^draft_id, ^fork_ref}}, 1_000
    send(session, {:consult_fork_timeout, draft_id, fork_ref})
    assert_receive {:consult_ask, _, ^draft_id, opts}, 1_000
    assert opts[:delivery_policy] == :checkpoint
    send(session, {:fork_answer, fork_ref, "Too late"})
    _ = :sys.get_state(session)

    refute Enum.any?(
             FakeProvider.calls(provider),
             &match?({:send_context, "Here is what the agent's notes say: Too late"}, &1)
           )
  end

  test "the target ending makes a waiting consult stale", ctx do
    alive = start_supervised!({Agent, fn -> true end})
    {id, session, provider} = start!(ctx, :never, %{alive_agent: alive})
    ask(provider, "Why?", "one")
    assert_receive {:consult_ask, _, draft_id, _}, 1_000
    Agent.update(alive, fn _ -> false end)
    send(session, {:consult_progress, draft_id})
    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: ^draft_id, status: "stale"}}}, 1_000

    assert eventually(fn ->
             {:send_context, "The agent has ended; the question is stale."} in FakeProvider.calls(provider)
           end)
  end

  test "an async listener tells the provider the agent must read the question", ctx do
    {_id, _session, provider} = start!(ctx, :never, %{listener_mode: :async})
    ask(provider, "Why?", "one")
    assert_receive {:consult_ask, _, _, _}, 1_000

    assert eventually(fn ->
             {:send_context, "The agent will see the question when it next reads its messages."} in FakeProvider.calls(
               provider
             )
           end)
  end

  test "waiting updates are sent only after a minute of operator silence", ctx do
    now = DateTime.utc_now()
    clock = start_supervised!({Agent, fn -> now end})
    {id, session, provider} = start!(ctx, :never, %{test_clock: clock})
    ask(provider, "Why?", "one")
    assert_receive {:consult_ask, _, draft_id, _}, 1_000
    send(session, {:consult_progress, draft_id})
    _ = :sys.get_state(session)
    refute Enum.any?(FakeProvider.calls(provider), &match?({:send_context, "Still waiting." <> _}, &1))
    Agent.update(clock, fn time -> DateTime.add(time, 30, :second) end)
    FakeProvider.emit(provider, %Events.UserTranscript{text: "I'm here", final?: false})
    assert_receive {:voice_conversation, ^id, %Events.UserTranscript{final?: false}}, 1_000
    Agent.update(clock, fn time -> DateTime.add(time, 30, :second) end)
    send(session, {:consult_progress, draft_id})
    _ = :sys.get_state(session)
    refute Enum.any?(FakeProvider.calls(provider), &match?({:send_context, "Still waiting." <> _}, &1))
    Agent.update(clock, fn time -> DateTime.add(time, 30, :second) end)
    send(session, {:consult_progress, draft_id})

    assert eventually(fn ->
             Enum.any?(FakeProvider.calls(provider), &match?({:send_context, "Still waiting." <> _}, &1))
           end)
  end

  test "socket receives a confirmable consult and sends its confirmation", ctx do
    {id, _session, provider} = start!(ctx)
    ask(provider, "Why?", "one")
    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: draft_id} = record}}, 1_000
    socket = WebSock.socket_state(instance: ctx.name) |> Map.put(:conversation_id, id)
    assert {:push, {:text, json}, ^socket} = Socket.handle_info({:voice_conversation, id, {:draft, record}}, socket)

    assert {:ok, %{"type" => "draft", "kind" => "consult", "status" => "proposed", "draft_id" => ^draft_id}} =
             VoiceConverse.Wire.decode(json)

    assert {:ok, ^socket} =
             Socket.handle_in({~s({"v":1,"type":"confirm_draft","draft_id":"#{draft_id}"}), :text}, socket)

    assert_receive {:consult_ask, _, ^draft_id, _}, 1_000
    assert_receive {:voice_conversation, ^id, {:draft, %{status: "confirmed"} = confirmed}}, 1_000
    assert {:push, {:text, json}, ^socket} = Socket.handle_info({:voice_conversation, id, {:draft, confirmed}}, socket)

    assert {:ok, %{"type" => "delivery", "status" => "confirmed", "draft_id" => ^draft_id}} =
             VoiceConverse.Wire.decode(json)
  end

  test "a timed-out send is uncertain and cannot be repeated until cleared", ctx do
    {id, _session, provider} = start!(ctx, :never, %{ask_timeout: true})
    ask(provider, "Why?", "one")
    assert_receive {:consult_ask, _, draft_id, _}, 1_000
    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: ^draft_id, status: "unknown"}}}, 1_000
    assert_receive {:fake_provider, :tool_result, "one", %{is_error: true, text: text}}, 1_000
    assert text =~ "uncertain"
    ask(provider, "Another?", "two")

    assert_receive {:fake_provider, :tool_result, "two", %{is_error: true, text: "A question is already waiting."}},
                   1_000

    assert {:ok, %{status: :discarded}} = VoiceConverse.discard_draft(ctx.name, id, draft_id, origin: :client)
  end

  test "a rejected send clears the open consult", ctx do
    {id, _session, provider} = start!(ctx, :never, %{ask_error: true})
    ask(provider, "Why?", "one")
    assert_receive {:consult_ask, _, draft_id, _}, 1_000
    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: ^draft_id, status: "failed"}}}, 1_000
    assert_receive {:fake_provider, :tool_result, "one", %{is_error: true}}, 1_000
    ask(provider, "Another?", "two")
    assert_receive {:consult_ask, _, _, _}, 1_000
  end

  test "a failed delivery record leaves the send outcome uncertain", ctx do
    writes = start_supervised!({Agent, fn -> 0 end})
    {id, session, provider} = start!(ctx, :first_in_session, %{ask_error: true})
    ask(provider, "Why?", "one")
    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: draft_id, status: "proposed"}}}, 1_000

    :sys.replace_state(session, fn state ->
      put_in(state.store.datasync, fn _ ->
        Agent.get_and_update(writes, fn count -> {if(count == 0, do: :ok, else: {:error, :eio}), count + 1} end)
      end)
    end)

    assert {:error, :outcome_unknown} = VoiceConverse.confirm_draft(ctx.name, id, draft_id, origin: :client)
    assert_receive {:consult_ask, _, ^draft_id, _}, 1_000
    :sys.replace_state(session, fn state -> put_in(state.store.datasync, &:file.datasync/1) end)
    ask(provider, "Another?", "two")

    assert_receive {:fake_provider, :tool_result, "two", %{is_error: true, text: "A question is already waiting."}},
                   1_000
  end

  test "an agent ending before confirmation marks the question stale", ctx do
    alive = start_supervised!({Agent, fn -> true end})
    {id, session, provider} = start!(ctx, :first_in_session, %{alive_agent: alive})
    ask(provider, "Why?", "one")
    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: draft_id, status: "proposed"}}}, 1_000
    Agent.update(alive, fn _ -> false end)
    send(session, {:consult_confirm_progress, draft_id})
    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: ^draft_id, status: "stale"}}}, 1_000
    refute_receive {:consult_ask, _, _, _}, 100
  end

  test "ending a session records the still-open question", ctx do
    {id, _session, provider} = start!(ctx, :never)
    ask(provider, "Why?", "one")
    assert_receive {:consult_ask, _, draft_id, _}, 1_000
    assert :ok = VoiceConverse.end_session(ctx.name, id)
    assert_receive {:voice_conversation, ^id, {:ended, :user_end}}, 1_000
    assert {:ok, records, _} = TranscriptStore.read(ctx.root, id)

    assert Enum.any?(
             records,
             &(&1["type"] == "delivery" and &1["draft_id"] == draft_id and &1["status"] == "open_at_session_end")
           )
  end

  test "provider specifications hide ask when the channel does not advertise it", ctx do
    {_id, session, provider} = start!(ctx, :never, %{ask_available: false})
    state = :sys.get_state(session)
    refute Enum.any?(VoiceConverse.Tools.specs(state.config, state.target), &(&1.name == "ask_agent"))

    assert Enum.any?(
             VoiceConverse.Tools.specs(state.config, Map.put(state.target, :ask_available, true)),
             &(&1.name == "ask_agent")
           )

    ask(provider, "Why?", "unavailable")

    assert_receive {:fake_provider, :tool_result, "unavailable", %{is_error: true, text: "Agent channel unavailable."}},
                   1_000

    refute_receive {:consult_ask, _, _, _}, 100
  end

  test "always confirmation applies to later questions too", ctx do
    {id, session, provider} = start!(ctx, :always)
    ask(provider, "Why?", "one")
    assert_receive {:voice_conversation, ^id, {:draft, %{draft_id: first, status: "proposed"}}}, 1_000
    assert {:ok, _} = VoiceConverse.confirm_draft(ctx.name, id, first, origin: :client)
    assert_receive {:consult_ask, _, ^first, _}, 1_000
    send(session, {:agent_reply, {:delivery, first}, "Answer"})
    assert eventually(fn -> {:send_context, "The agent answered: Answer"} in FakeProvider.calls(provider) end)
    ask(provider, "Another?", "two")
    assert_receive {:voice_conversation, ^id, {:draft, %{status: "proposed"}}}, 1_000
    refute_receive {:consult_ask, _, _, _}, 100
  end

  test "a fork-only channel can answer history but refuses fresh questions", ctx do
    {_id, session, provider} = start!(ctx, :never, %{fork: :native, ask_available: false})
    state = :sys.get_state(session)
    assert Enum.any?(VoiceConverse.Tools.specs(state.config, state.target), &(&1.name == "ask_agent"))

    FakeProvider.emit(provider, %Events.ToolCall{
      call_id: "one",
      name: "ask_agent",
      params: %{"question" => "Why?", "question_type" => "history"}
    })

    assert_receive {:consult_fork, _, ref}, 1_000
    send(session, {:fork_answer, ref, "Earlier reasoning"})

    assert eventually(fn ->
             {:send_context, "Here is what the agent's notes say: Earlier reasoning"} in FakeProvider.calls(provider)
           end)

    ask(provider, "Check the current tests", "two")

    assert_receive {:fake_provider, :tool_result, "two",
                    %{is_error: true, text: "Queued agent questions are unavailable."}},
                   1_000

    refute_receive {:consult_ask, _, _, _}, 100
  end

  test "a replay answer is identified as a summary", ctx do
    {_id, session, provider} = start!(ctx, :never, %{fork: :replay})

    FakeProvider.emit(provider, %Events.ToolCall{
      call_id: "one",
      name: "ask_agent",
      params: %{"question" => "Why?", "question_type" => "history"}
    })

    assert_receive {:consult_fork, _, ref}, 1_000
    send(session, {:fork_answer, ref, "A summary."})
    assert eventually(fn -> {:send_context, "The agent's summary says: A summary."} in FakeProvider.calls(provider) end)
  end

  defp start!(ctx, policy \\ :first_in_session, target_opts \\ %{}) do
    {:ok, config} =
      Config.new(
        name: ctx.name,
        transcript_root: ctx.root,
        credentials: StaticCredentials,
        briefing_source: ConsultBriefingSource,
        agent_channel: ConsultTestChannel,
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

    clock =
      case target_opts do
        %{test_clock: agent} -> fn -> Agent.get(agent, & &1) end
        _ -> &DateTime.utc_now/0
      end

    {:ok, id} =
      VoiceConverse.start_session(ctx.name, Map.merge(%{id: "target", test_pid: self()}, target_opts),
        client: self(),
        clock: clock,
        schedule_after: schedule,
        provider: {FakeProvider, [call_observer: self(), script: [%Events.ProviderConversationId{id: "provider"}]]}
      )

    assert_receive {:voice_conversation_state, ^id, :listening}, 1_000
    {:ok, session} = SessionRegistry.lookup(ctx.name, id)
    {id, session, :sys.get_state(session).provider_ref}
  end

  defp ask(provider, question, call_id),
    do:
      FakeProvider.emit(provider, %Events.ToolCall{
        call_id: call_id,
        name: "ask_agent",
        params: %{"question" => question}
      })

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end

defmodule ConsultBriefingSource do
  @behaviour VoiceConverse.Ports.BriefingSource
  def alive?(%{alive_agent: agent}), do: Agent.get(agent, & &1)
  def alive?(target), do: VoiceConverse.Testing.FakeBriefingSource.alive?(target)
  defdelegate describe_target(target), to: VoiceConverse.Testing.FakeBriefingSource
  defdelegate brief(target), to: VoiceConverse.Testing.FakeBriefingSource
  defdelegate details(target, section, opts), to: VoiceConverse.Testing.FakeBriefingSource
  defdelegate sections(target), to: VoiceConverse.Testing.FakeBriefingSource
  defdelegate subscribe(target, pid), to: VoiceConverse.Testing.FakeBriefingSource
end

defmodule ConsultTestChannel do
  @behaviour VoiceConverse.Ports.AgentChannel
  def ask(target, text, ref, opts) do
    send(target.test_pid, {:consult_ask, text, ref, opts})
    if target[:ask_timeout], do: Process.sleep(1_000)
    if target[:ask_error], do: {:error, :rejected}, else: {:ok, {:delivery, ref}}
  end

  defdelegate instruct(target, text, ref, opts), to: VoiceConverse.Testing.FakeAgentChannel

  def fork_query(target, text, opts) do
    ref = {:fork, opts[:ref]}
    send(target.test_pid, {:consult_fork, text, ref})
    {:ok, ref}
  end

  def subscribe(_target, _pid), do: :ok

  def capabilities(target),
    do: %{
      fork: Map.get(target, :fork, :none),
      listener_mode: Map.get(target, :listener_mode, :sync),
      ask: Map.get(target, :ask_available, true)
    }
end
