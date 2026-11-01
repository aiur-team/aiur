defmodule VoiceConverse.SessionTextTimingTest do
  use ExUnit.Case, async: false
  alias VoiceConverse.{Config, Events, TranscriptStore}
  alias VoiceConverse.Testing.{FakeBriefingSource, FakeProvider, StaticCredentials}

  defmodule AutomaticProvider do
    defdelegate descriptor(), to: FakeProvider
    def capabilities, do: %{FakeProvider.capabilities() | manual_truncation: false}
    defdelegate open(spec), to: FakeProvider
    defdelegate close(ref), to: FakeProvider
    defdelegate send_context(ref, text), to: FakeProvider
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "vc_timing_#{System.unique_integer([:positive])}")
    name = Module.concat([VoiceConverse, "Timing#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    StaticCredentials.put(%{fake: "test-secret"})
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)

    {:ok, config} =
      Config.new(
        name: name,
        limits: %{max_sessions: 2},
        providers: %{mode: if(tags[:text_only], do: :text, else: :voice)},
        transcript_root: root,
        credentials: StaticCredentials,
        briefing_source: FakeBriefingSource,
        provider: {FakeProvider, []},
        llm: "fake",
        cloud_disclosure_accepted: true
      )

    start_supervised!(VoiceConverse.child_spec(config))
    %{root: root, name: name}
  end

  test "interruption records heard prefix before later events and truncates provider once", ctx do
    {id, session, ref} = start_session(ctx)
    emit_turn(ref)
    interrupt(id, ref)
    :ok = FakeProvider.emit(ref, %Events.UserTranscript{text: "next", final?: true})
    report(ctx, id, 100)
    assert_receive {:voice_conversation, ^id, %Events.UserTranscript{final?: true}}, 1_000
    report(ctx, id, 100)
    records = records(ctx, id)
    assert [%{"text" => "é", "interrupted?" => true}] = turns(records)

    assert Enum.find_index(records, &(&1["type"] == "assistant_turn")) <
             Enum.find_index(records, &(&1["type"] == "user_turn"))

    assert Enum.count(FakeProvider.calls(ref), &(&1 == {:truncate, "t", 100})) == 1
    refute File.read!(:sys.get_state(session).store.path) =~ "offset_ms"
    refute File.read!(:sys.get_state(session).store.path) =~ "chars"
  end

  test "zero and beyond-last playback bounds record empty and full text", ctx do
    for {played, expected} <- [{0, ""}, {10_000, "é👩🏽‍💻!"}] do
      {id, _, ref} = start_session(ctx)
      emit_turn(ref)
      interrupt(id, ref)
      report(ctx, id, played)
      assert [%{"text" => ^expected, "interrupted?" => true}] = turns(records(ctx, id))
      :ok = VoiceConverse.end_session(ctx.name, id)
      assert_receive {:voice_conversation, ^id, {:ended, :user_end}}, 1_000
    end
  end

  test "provider truncation errors are recorded without ending the session", ctx do
    {id, session, ref} = start_session(ctx, FakeProvider, truncate_error: :provider_failed)
    emit_turn(ref)
    interrupt(id, ref)
    report(ctx, id, 100)

    assert [%{"text" => "é", "interrupted?" => true}] = turns(records(ctx, id))

    assert Enum.any?(
             records(ctx, id),
             &(&1["type"] == "provider_truncation_error" and &1["error"] =~ "provider_failed")
           )

    assert Process.alive?(session)

    :ok = FakeProvider.emit(ref, %Events.UserTranscript{text: "still here", final?: true})
    assert_receive {:voice_conversation, ^id, %Events.UserTranscript{final?: true}}, 1_000
  end

  test "missing playback report uses real two-second grace and retains full text", ctx do
    {id, _, ref} = start_session(ctx)
    emit_turn(ref)
    interrupt(id, ref)
    :ok = FakeProvider.emit(ref, %Events.UserTranscript{text: "after grace", final?: true})
    assert_receive {:voice_conversation, ^id, %Events.UserTranscript{final?: true}}, 3_000
    assert [%{"text" => "é👩🏽‍💻!", "interrupted?" => true}] = turns(records(ctx, id))
    refute Enum.any?(FakeProvider.calls(ref), &match?({:truncate, _, _}, &1))
  end

  test "without timings all partial text survives and automatic providers are not truncated",
       ctx do
    {id, _, ref} = start_session(ctx, AutomaticProvider)
    :ok = FakeProvider.emit(ref, %Events.AgentText{turn_id: "t", text: "untimed", final?: false})
    interrupt(id, ref)
    report(ctx, id, 0)
    assert [%{"text" => "untimed", "interrupted?" => true}] = turns(records(ctx, id))
    refute Enum.any?(FakeProvider.calls(ref), &match?({:truncate, _, _}, &1))
  end

  test "final voiced text remains truncatable across timing chunks", ctx do
    {id, _, ref} = start_session(ctx)

    for {text, offset} <- [{"é", 0}, {"👩🏽‍💻!", 100}] do
      :ok =
        FakeProvider.emit(
          ref,
          Events.AgentTextTiming.from_text_deltas(text,
            turn_id: "t",
            audio_offset_ms: offset,
            duration_ms: 200
          )
        )
    end

    :ok = FakeProvider.emit(ref, %Events.AgentText{turn_id: "t", text: "é👩🏽‍💻!", final?: true})
    interrupt(id, ref)
    report(ctx, id, 101)
    assert [%{"text" => "é👩🏽‍💻", "interrupted?" => true}] = turns(records(ctx, id))
  end

  test "normal playback persists once and session end flushes remaining voiced text", ctx do
    {id, _, ref} = start_session(ctx)
    emit_turn(ref)
    :ok = FakeProvider.emit(ref, %Events.AgentText{turn_id: "t", text: "é👩🏽‍💻!", final?: true})
    assert_receive {:voice_conversation, ^id, %Events.AgentText{final?: true}}, 1_000
    report(ctx, id, 999)
    report(ctx, id, 999)
    assert [%{"text" => "é👩🏽‍💻!"}] = turns(records(ctx, id))

    :ok =
      FakeProvider.emit(ref, Events.AgentTextTiming.from_text_deltas("tail", turn_id: "other"))

    assert_receive {:voice_conversation, ^id, %Events.AgentTextTiming{turn_id: "other"}}, 1_000
    :ok = VoiceConverse.end_session(ctx.name, id)
    assert_receive {:voice_conversation, ^id, {:ended, :user_end}}, 1_000

    assert Enum.sort(Enum.map(turns(records(ctx, id)), & &1["text"])) ==
             Enum.sort(["é👩🏽‍💻!", "tail"])
  end

  test "final text before audio can still be interrupted and integer provider ids survive the wire",
       ctx do
    {id, _, ref} = start_session(ctx)
    :ok = FakeProvider.emit(ref, %Events.AgentText{turn_id: 7, text: "ab", final?: true})

    :ok =
      FakeProvider.emit(
        ref,
        Events.AgentTextTiming.from_text_deltas("ab", turn_id: 7, duration_ms: 200)
      )

    :ok = FakeProvider.emit(ref, %Events.Interruption{turn_id: 7})
    assert_receive {:voice_conversation, ^id, %Events.Interruption{turn_id: 7}}, 1_000

    :ok =
      VoiceConverse.playback_state(ctx.name, id, %{
        "state" => "stopped",
        "turn_id" => "7",
        "played_until_ms" => 100
      })

    assert [%{"text" => "a", "interrupted?" => true}] = turns(records(ctx, id))
    assert {:truncate, 7, 100} in FakeProvider.calls(ref)
  end

  test "a report for another turn cannot settle interruption and an old frame retains full text",
       ctx do
    {id, session, ref} = start_session(ctx)
    emit_turn(ref)
    interrupt(id, ref)

    :ok =
      VoiceConverse.playback_state(ctx.name, id, %{
        "state" => "stopped",
        "turn_id" => "other",
        "played_until_ms" => 0
      })

    assert turns(records(ctx, id)) == []
    :ok = VoiceConverse.playback_state(ctx.name, id, %{"state" => "stopped"})
    assert turns(records(ctx, id)) == []
    # The timer token comes from the actual scheduling path.
    {turn, token, _} = :sys.get_state(session).interrupted_turn
    send(session, {:text_timing_grace, turn, token})
    :sys.get_state(session)
    assert [%{"text" => "é👩🏽‍💻!", "interrupted?" => true}] = turns(records(ctx, id))
    report(ctx, id, 0)
    assert [%{"text" => "é👩🏽‍💻!"}] = turns(records(ctx, id))
    refute Enum.any?(FakeProvider.calls(ref), &match?({:truncate, _, _}, &1))
  end

  @tag text_only: true
  test "text-only finals persist immediately and a new user turn saves an interrupted partial",
       ctx do
    {id, _, ref} = start_session(ctx)
    :ok = FakeProvider.emit(ref, %Events.AgentText{turn_id: "done", text: "final", final?: true})
    assert_receive {:voice_conversation, ^id, %Events.AgentText{final?: true}}, 1_000
    assert [%{"text" => "final"}] = turns(records(ctx, id))

    :ok =
      FakeProvider.emit(ref, %Events.AgentText{turn_id: "partial", text: "so far", final?: false})

    :ok = FakeProvider.emit(ref, %Events.UserTranscript{text: "stop", final?: true})
    assert_receive {:voice_conversation, ^id, %Events.UserTranscript{final?: true}}, 1_000

    assert [%{"text" => "final"}, %{"text" => "so far", "interrupted?" => true}] =
             turns(records(ctx, id))
  end

  defp start_session(ctx, provider \\ FakeProvider, fake_opts \\ []) do
    {:ok, id} =
      VoiceConverse.start_session(ctx.name, %{id: "target"},
        client: self(),
        provider: {provider, fake_opts}
      )

    assert_receive {:voice_conversation_state, ^id, :connecting}, 1_000
    {:ok, session} = VoiceConverse.SessionRegistry.lookup(ctx.name, id)
    ref = :sys.get_state(session).provider_ref
    :ok = FakeProvider.emit(ref, %Events.ProviderConversationId{id: "fake-id"})
    assert_receive {:voice_conversation_state, ^id, :listening}, 1_000
    {id, session, ref}
  end

  defp emit_turn(ref) do
    :ok = FakeProvider.emit(ref, %Events.AgentText{turn_id: "t", text: "é👩🏽‍💻!", final?: false})

    :ok =
      FakeProvider.emit(ref, %Events.AgentTextTiming{
        turn_id: "t",
        text: "é👩🏽‍💻!",
        chars: [{0, 1}, {100, 1}, {200, 1}],
        audio_offset_ms: 0,
        estimated: false
      })
  end

  defp interrupt(id, ref) do
    :ok = FakeProvider.emit(ref, %Events.Interruption{turn_id: "t"})
    assert_receive {:voice_conversation, ^id, %Events.Interruption{}}, 1_000
  end

  defp report(ctx, id, played),
    do:
      VoiceConverse.playback_state(ctx.name, id, %{
        "state" => "stopped",
        "turn_id" => "t",
        "played_until_ms" => played
      })

  defp records(ctx, id) do
    {:ok, records, _} = TranscriptStore.read(ctx.root, id)
    records
  end

  defp turns(records), do: Enum.filter(records, &(&1["type"] == "assistant_turn"))
end
