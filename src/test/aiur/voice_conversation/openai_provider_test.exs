defmodule Aiur.VoiceConversation.OpenAIProviderTest do
  use Aiur.TestSupport
  alias Aiur.VoiceConversation.OpenAIProvider

  defmodule Credentials do
    def fetch({_owner, :test}, :probe), do: {:ok, :present}

    def fetch({owner, :test}, :connect) do
      Process.put(:observer, owner)
      {:ok, "test-credential"}
    end
  end

  defmodule Transport do
    def connect(_url, _headers), do: {:ok, Process.get(:observer)}

    def send_text(owner, text) do
      send(owner, {:wire, Jason.decode!(text)})
      send(owner, {:provider_wire, self(), Jason.decode!(text)})
      {:ok, owner}
    end

    def close(_owner), do: :ok
  end

  defmodule SessionProvider do
    @behaviour VoiceConverse.Provider
    @impl true
    defdelegate descriptor(), to: OpenAIProvider
    @impl true
    defdelegate capabilities(), to: OpenAIProvider
    @impl true
    def open(spec) do
      observer = Keyword.fetch!(spec.fake, :observer)

      spec
      |> Map.put(:credentials, {Credentials, {observer, :test}})
      |> Map.put(:transport, Transport)
      |> OpenAIProvider.open()
    end

    @impl true
    defdelegate push_audio(ref, audio), to: OpenAIProvider
    @impl true
    defdelegate send_context(ref, text), to: OpenAIProvider
    @impl true
    defdelegate send_user_text(ref, text), to: OpenAIProvider
    @impl true
    defdelegate tool_result(ref, id, result), to: OpenAIProvider
    @impl true
    defdelegate close(ref), to: OpenAIProvider
  end

  test "OpenAI wire transcripts and summary reach the shared Executor handoff" do
    root = Aiur.TestSupport.tmp_root!("openai-handoff")
    instance = Module.concat(__MODULE__, "Instance#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    observer = self()

    {:ok, config} =
      VoiceConverse.Config.new(
        name: instance,
        credentials: Credentials,
        briefing_source: VoiceConverse.Testing.FakeBriefingSource,
        transcript_root: root,
        provider: {SessionProvider, [observer: observer]},
        llm: "gpt-realtime-2.1",
        cloud_disclosure_accepted: true,
        allowed_tools: ["get_status", "get_details", "record_summary", "end_conversation"]
      )

    start_supervised!(VoiceConverse.child_spec(config))
    start = fn owner, _opts -> VoiceConverse.start_session(instance, %{id: "executor"}, client: owner) end
    :ok = Aiur.ExecutorEvents.subscribe("executor.voice.session_ended")
    {:ok, monitor, id} = Aiur.VoiceConversation.Session.start(self(), instance: instance, start_session: start)
    ref = Process.monitor(monitor)
    receive_barrier({:provider_wire, provider, %{"type" => "session.update"}})
    send_frame(provider, %{type: "session.updated"})
    send_frame(provider, %{type: "conversation.item.input_audio_transcription.completed", transcript: "Ship it; who deploys? Try blue."})
    receive_barrier({:executor_voice, %VoiceConverse.Events.UserTranscript{final?: true}})
    send_frame(provider, %{type: "response.output_audio_transcript.done", item_id: "turn", transcript: "Recorded."})
    receive_barrier({:executor_voice, %VoiceConverse.Events.AgentText{final?: true}})
    summary = %{decisions: ["Ship it"], open_questions: ["Who deploys?"], ideas: ["Try blue"]}
    send_frame(provider, %{type: "response.function_call_arguments.done", call_id: "summary", name: "record_summary", arguments: Jason.encode!(summary)})
    receive_barrier({:executor_voice, {:summary_recorded, recorded}})
    assert recorded == summary
    send_frame(provider, %{type: "response.function_call_arguments.done", call_id: "end", name: "end_conversation", arguments: "{}"})
    receive_barrier({:executor_voice, {:receipt, %{id: event_id, summary_status: "structured"}}})
    receive_barrier({:DOWN, ^ref, :process, ^monitor, :normal})
    assert {:ok, events} = Aiur.ExecutorEvents.replay(["executor.voice.session_ended"], 0)
    event = Enum.find(events, &(&1["id"] == event_id))
    assert event["session_id"] == id
    assert event["transcript"] == [%{"role" => "user", "text" => "Ship it; who deploys? Try blue."}, %{"role" => "agent", "text" => "Recorded.", "turn_id" => "turn"}]
    assert event["summary"] == %{"status" => "structured", "decisions" => ["Ship it"], "open_questions" => ["Who deploys?"], "ideas" => ["Try blue"]}
    assert event["untrusted_fields"] == ["transcript", "summary"]
  end

  defp send_frame(provider, frame), do: send(provider, {:openai_realtime_transport, :text, Jason.encode!(frame)})

  test "the host supplies the same summary instructions and configured voice to the real adapter" do
    spec = %{
      owner: self(),
      credentials: {Credentials, {self(), :test}},
      audio_in: :pcm_16000,
      audio_out: :pcm_16000,
      llm: "gpt-realtime-2.1",
      system_prompt: "",
      context: "retained facts",
      first_message: nil,
      tools: [],
      fake: [voice_id: "cedar"],
      transport: Transport
    }

    {:ok, provider} = OpenAIProvider.open(spec)
    :sys.get_state(provider)
    assert_received {:wire, %{"type" => "session.update", "session" => session}}
    assert session["audio"]["output"]["voice"] == "cedar"
    assert session["instructions"] == Aiur.VoiceConversation.Provider.prompt() <> "\n\nretained facts"
    assert session["instructions"] =~ "Before end_conversation, call record_summary"
    assert OpenAIProvider.descriptor().id == :openai_realtime
    OpenAIProvider.close(provider)
  end
end
