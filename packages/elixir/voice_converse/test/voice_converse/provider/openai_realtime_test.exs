defmodule VoiceConverse.Provider.OpenAIRealtimeTest do
  use ExUnit.Case, async: true
  alias VoiceConverse.Events
  alias VoiceConverse.Provider.OpenAIRealtime, as: Provider
  alias VoiceConverse.Provider.OpenAIRealtime.PCM

  defmodule Credentials do
    def fetch(:openai, :probe), do: {:ok, :present}
    def fetch(:openai, :connect), do: {:ok, "test-secret"}
    def fetch(:missing, _), do: {:error, :missing}
  end

  defmodule Transport do
    def connect(url, headers) do
      # The observer is passed through the test-only process dictionary in open.
      observer = Process.get(:observer)
      send(observer, {:connect, url, headers})
      {:ok, observer}
    end

    def send_text(observer, text) do
      send(observer, {:wire, Jason.decode!(text)})
      {:ok, observer}
    end

    def close(observer) do
      send(observer, :closed)
      :ok
    end
  end

  # Credentials supplies the observer during the connect fetch, keeping every
  # test local with no shared environment or persistent-term state.
  defmodule LocalCredentials do
    def fetch({_observer, :probe}, :probe), do: {:ok, :present}

    def fetch({observer, :probe}, :connect) do
      Process.put(:observer, observer)
      {:ok, "test-secret"}
    end
  end

  defp spec do
    %{
      owner: self(),
      credentials: {LocalCredentials, {self(), :probe}},
      system_prompt: "read only",
      context: "current facts",
      first_message: nil,
      tools: [%{name: "get_status", description: "Read status", parameters: %{type: "object"}}],
      audio_in: :pcm_16000,
      audio_out: :pcm_16000,
      llm: "gpt-realtime-2.1",
      transport: Transport
    }
  end

  defp start do
    {:ok, pid} = Provider.open(spec())
    :sys.get_state(pid)
    assert_receive {:connect, url, headers}
    assert url == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1"
    assert headers == [{"Authorization", "Bearer test-secret"}]
    assert_receive {:wire, %{"type" => "session.update"} = setup}
    {pid, setup}
  end

  defp frame(pid, frame) do
    monitor = Process.monitor(pid)
    send(pid, {:openai_realtime_transport, :text, Jason.encode!(frame)})

    try do
      :sys.get_state(pid)
    catch
      :exit, _ -> receive do: ({:DOWN, ^monitor, :process, ^pid, _} -> :ok)
    end

    Process.demonitor(monitor, [:flush])
  end

  defp ready(pid) do
    frame(pid, %{type: "session.updated"})
    :sys.get_state(pid)
  end

  test "sets the GA formats, transcription, prompt and port tool schemas without retaining the key" do
    {pid, frame} = start()
    session = frame["session"]
    assert session["type"] == "realtime"
    assert session["instructions"] == "read only\n\ncurrent facts"
    assert session["audio"]["input"]["format"] == %{"type" => "audio/pcm", "rate" => 24_000}
    assert session["audio"]["input"]["transcription"] == %{"model" => "gpt-4o-mini-transcribe"}
    assert session["audio"]["output"]["voice"] == "marin"

    assert session["tools"] == [
             %{
               "type" => "function",
               "name" => "get_status",
               "description" => "Read status",
               "parameters" => %{"type" => "object"}
             }
           ]

    refute inspect(:sys.get_state(pid)) =~ "test-secret"
    Provider.close(pid)
    assert_receive :closed
  end

  test "streams 16 kHz mic input only after setup acknowledgement and emits 24 kHz output" do
    {pid, _} = start()
    audio = Base.encode64(<<0::little-signed-16, 300::little-signed-16, 600::little-signed-16>>)
    Provider.push_audio(pid, audio)
    :sys.get_state(pid)
    refute_received {:wire, _}
    ready(pid)
    assert_receive {:wire, %{"type" => "input_audio_buffer.append", "audio" => sent}}
    assert Base.decode64!(sent) == <<0::little-signed-16, 200::little-signed-16, 400::little-signed-16>>
    frame(pid, %{type: "response.output_audio.delta", item_id: "turn", delta: audio})

    assert_receive {:voice_conversation, ^pid,
                    %Events.AgentAudio{turn_id: "turn", format: :pcm_24000, data_b64: ^audio}}

    Provider.close(pid)
  end

  test "resampling preserves phase across odd sample chunks and rejects malformed PCM" do
    input =
      <<0::little-signed-16, 300::little-signed-16, 600::little-signed-16, 900::little-signed-16,
        1200::little-signed-16>>

    {:ok, whole, _} = PCM.convert(Base.encode64(input), <<>>)
    <<first::binary-size(2), rest::binary>> = input
    assert {:ok, "", tail} = PCM.convert(Base.encode64(first), <<>>)
    assert {:ok, ^whole, _} = PCM.convert(Base.encode64(rest), tail)

    assert Base.decode64!(whole) ==
             <<0::little-signed-16, 200::little-signed-16, 400::little-signed-16, 600::little-signed-16,
               800::little-signed-16, 1000::little-signed-16>>

    assert PCM.convert("!", <<>>) == {:error, :invalid_audio}
    assert PCM.convert(Base.encode64(<<1>>), <<>>) == {:error, :invalid_audio}
  end

  test "normalizes final transcripts and session identity; cuts playback and model context on barge-in" do
    {pid, _} = start()
    ready(pid)
    frame(pid, %{type: "session.created", session: %{id: "sess"}})
    frame(pid, %{type: "conversation.item.input_audio_transcription.completed", transcript: "status?"})
    frame(pid, %{type: "response.output_audio_transcript.done", item_id: "turn", transcript: "running"})
    frame(pid, %{type: "response.output_audio.delta", item_id: "turn", delta: "AAA="})
    frame(pid, %{type: "input_audio_buffer.speech_started"})
    assert_receive {:voice_conversation, ^pid, %Events.ProviderConversationId{id: "sess"}}
    assert_receive {:voice_conversation, ^pid, %Events.UserTranscript{text: "status?", final?: true}}
    assert_receive {:voice_conversation, ^pid, %Events.AgentText{text: "running", final?: true, turn_id: "turn"}}
    assert_receive {:voice_conversation, ^pid, %Events.Interruption{turn_id: "turn"}}

    assert_receive {:wire,
                    %{
                      "type" => "conversation.item.truncate",
                      "item_id" => "turn",
                      "content_index" => 0,
                      "audio_end_ms" => 0
                    }}

    Provider.close(pid)
  end

  test "executes completed tool arguments once and continues only after all parallel results and response.done" do
    {pid, _} = start()
    ready(pid)
    frame(pid, %{type: "response.created"})

    for id <- ["a", "b", "a"] do
      frame(pid, %{type: "response.function_call_arguments.done", call_id: id, name: "get_status", arguments: "{}"})
    end

    :sys.get_state(pid)
    assert_receive {:voice_conversation, ^pid, %Events.ToolCall{call_id: "a", name: "get_status", params: %{}}}
    assert_receive {:voice_conversation, ^pid, %Events.ToolCall{call_id: "b"}}
    refute_received {:voice_conversation, ^pid, %Events.ToolCall{}}
    for id <- ["a", "b"], do: Provider.tool_result(pid, id, %{text: "ok", is_error: false})
    :sys.get_state(pid)
    assert_receive {:wire, %{"item" => %{"type" => "function_call_output", "call_id" => "a", "output" => result}}}
    assert Jason.decode!(result) == %{"text" => "ok", "is_error" => false}
    assert_receive {:wire, %{"item" => %{"call_id" => "b"}}}
    refute_received {:wire, %{"type" => "response.create"}}
    frame(pid, %{type: "response.done", response: %{status: "completed"}})
    assert_receive {:wire, %{"type" => "response.create"}}
    Provider.tool_result(pid, "a", %{text: "duplicate", is_error: false})
    :sys.get_state(pid)
    refute_received {:wire, _}
    Provider.close(pid)
  end

  test "context is passive while user text creates a response" do
    {pid, _} = start()
    ready(pid)
    Provider.send_context(pid, "facts")
    Provider.send_user_text(pid, "status?")
    :sys.get_state(pid)
    assert_receive {:wire, %{"item" => %{"role" => "system", "content" => [%{"text" => "facts"}]}}}
    assert_receive {:wire, %{"item" => %{"role" => "user", "content" => [%{"text" => "status?"}]}}}
    assert_receive {:wire, %{"type" => "response.create"}}
    Provider.close(pid)
  end

  test "upstream errors never expose raw payload and close the socket" do
    for {code, expected} <- [
          {"invalid_api_key", :provider_auth},
          {"insufficient_quota", :provider_quota},
          {"unknown", :provider_error}
        ] do
      {pid, _} = start()
      frame(pid, %{type: "error", error: %{code: code, message: "test-secret"}})
      assert_receive {:voice_conversation, ^pid, %Events.Error{code: ^expected, message: message}}
      refute message =~ "test-secret"
      assert_receive {:voice_conversation, ^pid, %Events.Closed{reason: ^expected}}
      assert_receive :closed
    end
  end

  test "initialization timeout, malformed tool arguments and queue overflow fail closed" do
    for failure <- [:timeout, :tool, :overflow] do
      {pid, _} = start()

      case failure do
        :timeout ->
          send(pid, :initialization_timeout)

        :tool ->
          frame(pid, %{type: "response.function_call_arguments.done", call_id: "a", name: "get_status", arguments: "[]"})

        :overflow ->
          Provider.push_audio(pid, String.duplicate("a", 426_669))
      end

      assert_receive {:voice_conversation, ^pid, %Events.Error{}}
      assert_receive {:voice_conversation, ^pid, %Events.Closed{}}
      assert_receive :closed
    end
  end

  test "registry selects the implemented provider and missing credentials refuse without a socket" do
    {:ok, config} =
      VoiceConverse.Config.new(
        name: __MODULE__,
        credentials: Credentials,
        briefing_source: VoiceConverse.Testing.FakeBriefingSource,
        transcript_root: "/unused",
        providers: %{preference: [:openai_realtime]}
      )

    assert {:ok, %{id: :openai_realtime, status: :ready}, skipped: []} = VoiceConverse.Providers.resolve(config)

    assert {:error, %Events.Error{code: :unconfigured}} =
             Provider.open(%{spec() | credentials: {Credentials, :missing}})

    refute_received {:connect, _, _}
  end

  test "transport failure and owner death clean up" do
    {pid, _} = start()
    send(pid, {:openai_realtime_transport, :error, :opaque_secret})
    assert_receive {:voice_conversation, ^pid, %Events.Error{code: :provider_unavailable}}
    assert_receive :closed
    owner = spawn(fn -> receive(do: (:stop -> :ok)) end)
    {:ok, pid} = Provider.open(%{spec() | owner: owner})
    :sys.get_state(pid)
    send(owner, :stop)
    ref = Process.monitor(pid)
    receive do: ({:DOWN, ^ref, :process, ^pid, :normal} -> :ok)
    assert_received :closed
  end
end
