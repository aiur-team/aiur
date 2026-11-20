defmodule VoiceConverse.AgentIdTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Config, Events}
  alias VoiceConverse.Provider.ElevenLabsAgents
  alias VoiceConverse.Providers.ElevenLabsAgents, as: ElevenLabsProvider
  alias VoiceConverse.Testing.{FakeBriefingSource, FakeProvider, StaticCredentials}

  @base [transcript: :none, credentials: StaticCredentials, briefing_source: FakeBriefingSource]

  @ready @base ++
           [
             provider: ElevenLabsProvider,
             llm: "eleven-model",
             cloud_disclosure_accepted: true,
             agent_id: "agent_configured"
           ]

  @missing [{"a missing identifier", nil}, {"a blank identifier", ""}, {"a whitespace-only identifier", "   "}]

  defmodule RecordingProvider do
    @moduledoc false

    # A hosted-agent adapter that reports the session spec it was opened with, so a test can see
    # what the session handed the provider without opening any transport.

    def descriptor, do: VoiceConverse.Provider.ElevenLabsAgents.descriptor()

    def open(spec) do
      send(Keyword.fetch!(spec.fake, :observer), {:opened, spec})
      Agent.start_link(fn -> spec end)
    end

    def push_audio(_ref, _audio), do: :ok
    def send_context(_ref, _text), do: :ok
    def send_user_text(_ref, _text), do: :ok
    def tool_result(_ref, _call_id, _result), do: :ok
    def close(ref), do: Agent.stop(ref)
  end

  setup do
    StaticCredentials.put(%{elevenlabs: "xi-test-secret"})
    root = Path.join(System.tmp_dir!(), "voice_converse_agent_id_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  describe "a configured identifier" do
    test "is accepted and lets availability and session start through" do
      {:ok, config} = Config.new(@ready)

      assert config.agent_id == "agent_configured"
      assert :ok = Config.check_session_start(config)
      assert :ok = VoiceConverse.availability(config)
    end

    test "reaches the provider session specification as an identifier, not a credential" do
      {:ok, config} = Config.new(Keyword.put(@ready, :provider, {RecordingProvider, [observer: self()]}))
      name = start_instance(config)

      assert {:ok, id} = VoiceConverse.start_session(name, %{id: "target"}, [])
      assert_receive {:opened, spec}, 1_000

      assert spec.agent_id == "agent_configured"
      assert spec.credentials == {StaticCredentials, :elevenlabs_agents}
      refute inspect(spec) =~ "xi-test-secret"
      assert {:ok, _pid} = VoiceConverse.SessionRegistry.lookup(name, id)
    end
  end

  for {label, value} <- @missing do
    test "#{label} is refused by availability and session start" do
      {:ok, config} = Config.new(Keyword.put(@ready, :agent_id, unquote(value)))

      assert {:error, %{field: :agent_id, reason: :missing}} = Config.check_session_start(config)
      assert {:unavailable, {:not_configured, :agent_id}} = VoiceConverse.availability(config)
    end

    test "#{label} refuses session start before the provider opens" do
      {:ok, config} =
        Config.new(Keyword.merge(@ready, agent_id: unquote(value), provider: {RecordingProvider, [observer: self()]}))

      name = start_instance(config)

      assert {:error, :agent_id} = VoiceConverse.start_session(name, %{id: "target"}, [])
      refute_receive {:opened, _spec}, 50
    end
  end

  test "a non-string identifier is invalid at build time" do
    assert {:error, %{field: :agent_id, reason: :invalid}} = Config.new(Keyword.put(@base, :agent_id, :agent))
  end

  test "an adapter that is not a hosted agent needs no identifier" do
    {:ok, config} =
      Config.new(Keyword.merge(@base, provider: {FakeProvider, []}, llm: "some-model", cloud_disclosure_accepted: true))

    assert :ok = Config.check_session_start(config)
    assert :ok = VoiceConverse.availability(config)
  end

  test "an adapter chosen at start time is checked even when the config names another" do
    {:ok, config} = Config.new(Keyword.merge(@base, provider: {FakeProvider, []}, llm: "some-model"))

    assert :ok = Config.check_agent_id(config, FakeProvider)

    for hosted <- [ElevenLabsProvider, ElevenLabsAgents] do
      assert {:error, %{field: :agent_id, reason: :missing}} = Config.check_agent_id(config, hosted)
      assert {:error, %{field: :agent_id, reason: :missing}} = Config.check_agent_id(config, {hosted, []})
    end
  end

  test "the adapter refuses a missing identifier before requesting a signed URL" do
    for agent_id <- [nil, "", "   "] do
      assert {:error, %Events.Error{code: :unconfigured}} = ElevenLabsAgents.open(adapter_spec(agent_id))
    end
  end

  defp adapter_spec(agent_id) do
    %{
      owner: self(),
      credentials: {StaticCredentials, :elevenlabs},
      agent_id: agent_id,
      system_prompt: "system",
      context: "context",
      first_message: nil,
      voice_id: nil,
      tools: [],
      audio_in: :pcm_16000,
      audio_out: :pcm_16000,
      fake: [],
      http: fn _url, _opts -> flunk("a signed URL was requested without an Agent id") end
    }
  end

  defp start_instance(config) do
    start_supervised!(VoiceConverse.child_spec(config))
    config.name
  end
end
