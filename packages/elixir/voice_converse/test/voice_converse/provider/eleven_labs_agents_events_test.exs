defmodule VoiceConverse.Provider.ElevenLabsAgentsEventsTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.Events
  alias VoiceConverse.Provider.ElevenLabsAgents
  alias VoiceConverse.Provider.ElevenLabsAgents.Decoder

  @fixtures Path.expand("../../fixtures/elevenlabs_agents", __DIR__)

  defmodule Credentials do
    def fetch(:elevenlabs, :probe), do: {:ok, :present}
    def fetch(:elevenlabs, :connect), do: {:ok, "REDACTED_KEY"}
  end

  defmodule Transport do
    def connect(_url, []), do: {:ok, Process.get(:event_test_owner)}

    def send_text(owner, text) do
      send(owner, {:sent, Jason.decode!(text)})
      {:ok, owner}
    end

    def close(_owner), do: :ok
  end

  test "documented fixtures decode to normalized structs with exact contents" do
    expected = expected_events()
    assert length(frames()) == length(expected)

    for {frame, event} <- Enum.zip(frames(), expected) do
      assert Decoder.decode(frame, %{audio_out: :pcm_24000, turn_id: 7}) == {:ok, event}
      assert Events.event?(event)

      for type <-
            ~w(user_transcript agent_response agent_response_correction audio_event interruption_event client_tool_call) do
        refute inspect(event) =~ type
      end
    end
  end

  test "malformed and unknown inputs are classified without leaking raw frames" do
    for frame <- [
          "{",
          "null",
          "[]",
          42,
          %{"type" => "audio"},
          %{"type" => "user_transcript", "user_transcription_event" => %{"user_transcript" => 7}},
          %{"type" => "client_tool_call", "client_tool_call" => %{"parameters" => []}}
        ] do
      assert Decoder.decode(frame) == {:error, :malformed_event}
    end

    assert Decoder.decode(%{"type" => "future_event", "secret" => "hidden"}) == {:ignore, "future_event"}
  end

  test "adapter forwards fixtures in order and finalizes the latest transcript exactly once" do
    provider = open_provider()
    Enum.each(frames(), &send_frame(provider, &1))
    :sys.get_state(provider)
    expected = List.insert_at(expected_events(), 2, %Events.UserTranscript{text: "start run", final?: true})
    assert take_events(provider) == expected
    assert ElevenLabsAgents.capabilities().events == Events.all()
  end

  test "no final without an agent turn; corrections and audio can each start the next turn" do
    for response <- Enum.slice(frames(), 3, 2) do
      provider = open_provider()
      send_frame(provider, hd(frames()))
      :sys.get_state(provider)
      assert take_events(provider) == [%Events.UserTranscript{text: "start", final?: false}]
      send_frame(provider, response)
      send_frame(provider, response)
      :sys.get_state(provider)
      assert [%Events.UserTranscript{text: "start", final?: true}, first, second] = take_events(provider)
      assert first == second
      assert match?(%Events.AgentText{}, first) or match?(%Events.AgentAudio{}, first)
    end
  end

  test "unknown and malformed events are counted and do not reach the owner" do
    provider = open_provider()
    names = for name <- [:unknown_event, :malformed_event], do: [:voice_converse, :provider, name]
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(handler, names, &__MODULE__.telemetry/4, {self(), provider})
    on_exit(fn -> :telemetry.detach(handler) end)
    send_frame(provider, %{"type" => "future_event", "secret" => "hidden"})
    send_frame(provider, "{")
    send_frame(provider, %{"type" => "audio"})
    :sys.get_state(provider)
    assert_received {:counted, [:voice_converse, :provider, :unknown_event], %{count: 1}, %{type: "future_event"}}
    assert_received {:counted, [:voice_converse, :provider, :malformed_event], %{count: 1}, %{}}
    assert_received {:counted, [:voice_converse, :provider, :malformed_event], %{count: 1}, %{}}
    assert take_events(provider) == []
  end

  test "tool results round trip through the public facade without confirmation; no-response and duplicate results stay local" do
    provider = open_provider()
    frame = List.last(frames())
    send_frame(provider, frame)
    :sys.get_state(provider)
    assert [%Events.ToolCall{call_id: "call-1", name: "unknown_tool"}] = take_events(provider)
    facade = VoiceConverse.Providers.ElevenLabsAgents
    :ok = facade.tool_result(provider, "call-1", %{text: "Started", is_error: false})
    :sys.get_state(provider)

    assert_received {:sent,
                     %{
                       "type" => "client_tool_result",
                       "tool_call_id" => "call-1",
                       "result" => "Started",
                       "is_error" => false
                     }}

    send_frame(provider, put_in(frame, ["client_tool_call", "tool_call_id"], "error-call"))
    :ok = facade.tool_result(provider, "error-call", %{text: "Unknown tool", is_error: true})
    :sys.get_state(provider)

    assert_received {:sent,
                     %{
                       "type" => "client_tool_result",
                       "tool_call_id" => "error-call",
                       "result" => "Unknown tool",
                       "is_error" => true
                     }}

    :ok = facade.tool_result(provider, "call-1", %{text: "duplicate", is_error: false})
    send_frame(provider, put_in(frame, ["client_tool_call", "expects_response"], false))
    :ok = facade.tool_result(provider, "call-1", %{text: "no response", is_error: false})
    :sys.get_state(provider)
    refute_received {:sent, _}
  end

  test "documented nested ping receives the matching pong" do
    provider = open_provider()
    send_frame(provider, %{"type" => "ping", "ping_event" => %{"event_id" => 12345, "ping_ms" => 50}})
    :sys.get_state(provider)
    assert_received {:sent, %{"type" => "pong", "event_id" => 12345}}
  end

  # Future regression guard: synthetic fixtures contain no credentials independently of the production mapping.
  test "fixtures contain no secrets" do
    paths = Path.wildcard(Path.join(@fixtures, "*.ndjson"))
    assert length(paths) > 0

    for path <- paths do
      contents = File.read!(path)

      for secret <- ["xi-api-key", "sk_", "signed_url", "token="] do
        refute contents =~ secret
      end
    end
  end

  def telemetry(name, measurements, metadata, {owner, provider}) do
    if self() == provider, do: send(owner, {:counted, name, measurements, metadata})
  end

  defp expected_events do
    [
      %Events.UserTranscript{text: "start", final?: false},
      %Events.UserTranscript{text: "start run", final?: false},
      %Events.AgentText{turn_id: "turn-1", text: "Starting.", final?: true},
      %Events.AgentText{turn_id: "turn-1", text: "Started.", final?: true},
      %Events.AgentAudio{turn_id: 7, format: :pcm_24000, data_b64: "AAA="},
      %Events.Interruption{turn_id: 7},
      %Events.ToolCall{call_id: "call-1", name: "unknown_tool", params: %{"command" => "start run"}}
    ]
  end

  defp frames do
    Path.join(@fixtures, "documented.ndjson")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp open_provider do
    owner = self()

    {:ok, provider} =
      ElevenLabsAgents.open(%{
        owner: owner,
        credentials: {Credentials, :elevenlabs},
        system_prompt: "test",
        context: "test",
        first_message: nil,
        audio_out: :pcm_24000,
        transport: Transport,
        http: fn _, _ ->
          Process.put(:event_test_owner, owner)
          {:ok, 200, ~s({"signed_url":"wss://example.invalid/REDACTED"})}
        end
      })

    :sys.get_state(provider)
    assert_received {:sent, %{"type" => "conversation_initiation_client_data"}}
    provider
  end

  defp send_frame(provider, frame) do
    text = if is_binary(frame), do: frame, else: Jason.encode!(frame)
    send(provider, {:elevenlabs_agents_transport, :text, text})
  end

  defp take_events(provider) do
    receive do
      {:voice_conversation, ^provider, event} -> [event | take_events(provider)]
    after
      0 -> []
    end
  end
end
