defmodule VoiceConverse.Testing.FakeProviderTest do
  # Session tests (MP-E6-C4..C7) rely on these semantics, so they are pinned here.
  use ExUnit.Case, async: true

  alias VoiceConverse.Events
  alias VoiceConverse.Testing.{FakeProvider, StaticCredentials}

  defp spec(extra \\ %{}) do
    Map.merge(
      %{
        owner: self(),
        credentials: {StaticCredentials, :fake},
        system_prompt: "role",
        first_message: nil,
        context: "ctx",
        tools: [],
        audio_in: :pcm_16000,
        audio_out: :pcm_16000
      },
      extra
    )
  end

  test "fake records every behaviour call in order, with arguments" do
    {:ok, ref} = FakeProvider.open(spec())

    :ok = FakeProvider.push_audio(ref, "AAAA")
    :ok = FakeProvider.send_context(ref, "briefing v2")
    :ok = FakeProvider.send_user_text(ref, "typed")
    :ok = FakeProvider.tool_result(ref, "call-1", "done")
    :ok = FakeProvider.announce(ref, "build finished", when: :idle)
    :ok = FakeProvider.truncate(ref, "t1", 1_200)
    :ok = FakeProvider.close(ref)

    assert FakeProvider.calls(ref) == [
             {:push_audio, "AAAA"},
             {:send_context, "briefing v2"},
             {:send_user_text, "typed"},
             {:tool_result, "call-1", "done"},
             {:announce, "build finished", [when: :idle]},
             {:truncate, "t1", 1_200},
             :close
           ]
  end

  test "emitted events reach the owner as normalized structs, in emit order" do
    {:ok, ref} = FakeProvider.open(spec())

    events = [
      %Events.UserTranscript{text: "hi", final?: true},
      %Events.AgentText{turn_id: "t1", text: "hello", final?: false},
      %Events.ToolCall{call_id: "c1", name: "get_status", params: %{}}
    ]

    Enum.each(events, &FakeProvider.emit(ref, &1))

    for event <- events, do: assert_receive({:voice_conversation, ^ref, ^event})
    assert Process.info(self(), :messages) == {:messages, []}
  end

  test "events reach the spec owner, not the process that emits them" do
    test_pid = self()
    owner = spawn_link(fn -> receive(do: (msg -> send(test_pid, {:owner_got, msg}))) end)
    {:ok, ref} = FakeProvider.open(spec(%{owner: owner}))

    FakeProvider.emit(ref, %Events.Interruption{turn_id: "t1"})

    assert_receive {:owner_got, {:voice_conversation, ^ref, %Events.Interruption{turn_id: "t1"}}}
    refute_received {:voice_conversation, _, _}
  end

  test "a scripted opening is delivered before later emits" do
    script = [%Events.ProviderConversationId{id: "conv-1"}, %Events.AgentText{turn_id: "t0", text: "hi", final?: true}]
    {:ok, ref} = FakeProvider.open(spec(%{fake: [script: script]}))
    FakeProvider.emit(ref, %Events.Closed{reason: :normal})

    assert_receive {:voice_conversation, ^ref, first}
    assert_receive {:voice_conversation, ^ref, second}
    assert_receive {:voice_conversation, ^ref, third}
    assert [first, second, third] == script ++ [%Events.Closed{reason: :normal}]
  end

  test "a raw provider term cannot be emitted" do
    {:ok, ref} = FakeProvider.open(spec())

    assert_raise ArgumentError, fn -> FakeProvider.emit(ref, %{"type" => "agent_response"}) end
    assert_raise ArgumentError, fn -> FakeProvider.emit(ref, %URI{}) end
    refute_received {:voice_conversation, _, _}
  end

  test "open and preflight failures are scriptable and come back as Error structs" do
    error = Events.Error.new(:provider_auth, "key rejected")

    assert {:error, ^error} = FakeProvider.open(spec(%{fake: [open_error: error]}))
    assert {:error, ^error} = FakeProvider.preflight(spec(%{fake: [preflight_error: error]}))
    assert :ok = FakeProvider.preflight(spec())
  end

  test "the fake dies with the process that opened it" do
    test_pid = self()

    opener =
      spawn(fn ->
        {:ok, ref} = FakeProvider.open(spec())
        send(test_pid, {:ref, ref})
        receive(do: (:stop -> :ok))
      end)

    assert_receive {:ref, ref}
    mon = Process.monitor(ref)
    Process.exit(opener, :kill)
    assert_receive {:DOWN, ^mon, :process, ^ref, _}
  end

  test "the fake declares every event and manual truncation" do
    assert %{events: events, text_only?: false, manual_truncation: true} = FakeProvider.capabilities()
    assert events == Events.all()
    assert %{id: :fake, family: :speech_to_speech, needs: []} = FakeProvider.descriptor()
  end
end
