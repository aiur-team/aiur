defmodule Aiur.Config.Schema.VoiceConversationProvidersTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema
  alias Aiur.VoiceConverse.Host.Config, as: HostConfig

  test "default cascade parts map on a cold VM before the core is loaded" do
    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))

    script = """
    settings = Aiur.Config.Schema.VoiceConversation.__struct__()
    case Aiur.VoiceConverse.Host.Config.build(settings, "/unused/voice") do
      {:ok, config} -> IO.inspect(config.providers.cascade)
      error -> raise inspect(error)
    end
    """

    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script]
    {output, status} = System.cmd(System.find_executable("elixir"), args, env: [{"ERL_FLAGS", "+S 2:2"}], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "stt: [:browser_stt]"
    assert output =~ "tts: [:browser_tts]"
  end

  test "omitted providers use the core preference and leave model choices unset" do
    assert {:ok, settings} = Schema.parse(%{})
    providers = settings.voice.conversation.providers
    assert providers.preference == VoiceConverse.Providers.default_preference()
    assert hd(providers.preference) == :elevenlabs_agents
    assert providers.openai.live_model == nil
    assert providers.openai.realtime_model == nil
    assert providers.gemini.live_model == nil
  end

  test "invalid options and cascade values fail loading with their full paths" do
    for {attrs, path} <- [
          {%{"preference" => ["invented"]}, "preference"},
          {%{"mode" => "silent"}, "mode"},
          {%{"on_missing_credential" => "ignore"}, "on_missing_credential"},
          {%{"cascade" => %{"stt" => ["invented"]}}, "cascade.stt"},
          {%{"cascade" => %{"tts" => ["invented"]}}, "cascade.tts"},
          {%{"cascade" => %{"llm" => "missing-vendor"}}, "cascade.llm"}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"voice" => %{"conversation" => %{"providers" => attrs}}})
      assert message =~ "voice.conversation.providers.#{path}"
    end
  end

  test "every provider key maps from YAML into the core config" do
    yaml = """
    voice:
      conversation:
        providers:
          preference: [openai_live, elevenlabs_agents, gemini_live, cascade]
          mode: text
          on_missing_credential: text_only
          openai: {live_model: chosen-live, realtime_model: chosen-realtime}
          gemini: {live_model: chosen-gemini}
          cascade:
            stt: [elevenlabs_stt, browser_stt]
            llm: anthropic:chosen-model
            tts: [elevenlabs_tts, browser_tts]
    """

    assert {:ok, attrs} = YamlElixir.read_from_string(yaml)
    assert {:ok, settings} = Schema.parse(attrs)
    assert {:ok, config} = HostConfig.build(settings.voice.conversation, "/unused/voice")
    assert config.providers.preference == [:openai_live, :elevenlabs_agents, :gemini_live, :cascade]
    assert config.providers.mode == :text
    assert config.providers.on_missing_credential == :text_only
    assert config.providers.openai == %{live_model: "chosen-live", realtime_model: "chosen-realtime"}
    assert config.providers.gemini == %{live_model: "chosen-gemini"}
    assert config.providers.cascade == %{stt: [:elevenlabs_stt, :browser_stt], llm: "anthropic:chosen-model", tts: [:elevenlabs_tts, :browser_tts]}
  end
end
