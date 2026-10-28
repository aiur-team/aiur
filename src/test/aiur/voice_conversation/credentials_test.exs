defmodule Aiur.VoiceConversation.CredentialsTest do
  use ExUnit.Case, async: false

  alias Aiur.VoiceConversation.Credentials
  alias Aiur.Workflow

  setup do
    previous = Application.get_env(:aiur, :workflow_file_path)
    dir = Aiur.TestSupport.tmp_root!("voice-conversation-credentials")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config")

    on_exit(fn ->
      if is_nil(previous), do: Workflow.clear_workflow_file_path(), else: Workflow.set_workflow_file_path(previous)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{path: path}
  end

  test "probe reveals presence only, connection resolves the host credential", %{path: path} do
    File.write!(path, """
    tracker:
      kind: memory
    elevenlabs:
      api_key: test-voice-credential
    """)

    Workflow.set_workflow_file_path(path)
    assert Credentials.fetch(:elevenlabs_agents, :probe) == {:ok, :present}
    assert Credentials.fetch(:elevenlabs_agents, :connect) == {:ok, "test-voice-credential"}
    assert Credentials.fetch(:elevenlabs, :delete) == {:ok, "test-voice-credential"}
    assert Credentials.fetch(:unknown, :connect) == {:error, :missing}
  end

  test "disabled host credential refuses sessions even with configured secret", %{path: path} do
    File.write!(path, """
    tracker:
      kind: memory
    elevenlabs:
      enabled: false
      api_key: test-voice-credential
    """)

    Workflow.set_workflow_file_path(path)
    assert Credentials.fetch(:elevenlabs_agents, :probe) == {:error, :missing}
    assert Credentials.fetch(:elevenlabs_agents, :connect) == {:error, :missing}
  end
end
