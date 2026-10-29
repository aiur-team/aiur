defmodule Aiur.VoiceConverse.Host.ConfigTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Schema.VoiceConversation, as: Settings
  alias Aiur.VoiceConverse.Host.Config

  test "builds under the configured conversation state directory" do
    root = Path.join(System.tmp_dir!(), "voice-host-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :conversation_state_dir)
    Application.put_env(:aiur, :conversation_state_dir, root)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :conversation_state_dir, previous), else: Application.delete_env(:aiur, :conversation_state_dir)
    end)

    assert {:ok, config} = Config.build(%Settings{})
    assert config.transcript_root == Path.join(root, "voice")
    assert config.briefing_source == Aiur.VoiceConverse.Host.BriefingSource
    assert config.agent_channel == Aiur.VoiceConverse.Host.AgentChannel
    assert config.credentials == Aiur.VoiceConverse.Host.Credentials
  end
end
