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

  test "OpenAI probe returns presence and connect resolves only the daemon key", %{path: path} do
    previous = System.get_env("OPENAI_API_KEY")

    on_exit(fn ->
      if previous, do: System.put_env("OPENAI_API_KEY", previous), else: System.delete_env("OPENAI_API_KEY")
    end)

    File.write!(path, """
    tracker:
      kind: memory
    elevenlabs:
      enabled: false
    voice:
      conversation:
        provider: openai_realtime
        llm: gpt-realtime-2.1
        cloud_disclosure_accepted: true
    """)

    Workflow.set_workflow_file_path(path)
    System.put_env("OPENAI_API_KEY", "test-openai-voice")
    assert Credentials.fetch(:openai_realtime, :probe) == {:ok, :present}
    assert Credentials.fetch(:openai_realtime, :connect) == {:ok, "test-openai-voice"}
    assert Aiur.VoiceConversation.availability() == :ok
    System.put_env("OPENAI_API_KEY", " ")
    assert Credentials.fetch(:openai_realtime, :probe) == {:error, :missing}
    assert Aiur.VoiceConversation.availability() == {:unavailable, :missing_credentials}
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
