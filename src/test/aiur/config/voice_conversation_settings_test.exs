defmodule Aiur.Config.VoiceConversationSettingsTest do
  use ExUnit.Case, async: false

  alias Aiur.Workflow

  setup do
    previous = Application.get_env(:aiur, :workflow_file_path)
    dir = Aiur.TestSupport.tmp_root!("aiur-voice-conversation-test")
    path = Path.join([dir, ".aiur", "config"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    tracker:
      kind: memory
    voice:
      conversation:
        llm: some-model
        roles_dir: voice/roles
    """)

    Workflow.set_workflow_file_path(path)

    on_exit(fn ->
      if is_nil(previous), do: Workflow.clear_workflow_file_path(), else: Workflow.set_workflow_file_path(previous)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # Role files live next to the config, like prompt_file; a cwd-relative path would break
  # whenever aiur runs from another directory.
  test "reads the active config and resolves roles_dir next to the config file", %{dir: dir} do
    settings = Aiur.Config.voice_conversation()

    assert settings.llm == "some-model"
    assert settings.roles_dir == Path.join([dir, ".aiur", "voice", "roles"])
    assert settings.daily_minutes_cap == 60
  end
end
