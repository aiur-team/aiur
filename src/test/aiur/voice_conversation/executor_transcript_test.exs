defmodule Aiur.VoiceConversation.ExecutorTranscriptTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.RemoteControl
  alias Aiur.VoiceConversation.ExecutorTranscript

  setup do
    root = Aiur.TestSupport.tmp_root!("voice-executor-transcript")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    id = "f3d44786-4e30-4809-bf91-e9798f7b36e1"
    cwd = Path.join(root, "repo")
    config_dir = Path.join(root, "claude-profile")
    path = RemoteControl.session_transcript_path(cwd, id, projects_dir: Path.join(config_dir, "projects"))
    File.mkdir_p!(Path.dirname(path))
    session = %{"state" => "live", "harness" => "claude", "session_id" => id, "cwd" => cwd, "config_dir" => config_dir}
    %{path: path, session: session}
  end

  test "uses the registered native session and retains only recent conversational text", %{path: path, session: session} do
    records = [
      %{"type" => "user", "message" => %{"content" => "Earlier request"}},
      %{"type" => "user", "message" => %{"content" => "Latest request"}},
      %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => "Latest answer"}, %{"type" => "tool_use", "id" => "tool1", "name" => "Bash", "input" => %{"command" => "echo private"}}]}
      }
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    assert {:ok, %{events: events}} = ExecutorTranscript.read_session(session, 2)
    assert events == [%{role: "user", body: "Latest request"}, %{role: "assistant", body: "Latest answer"}]
  end

  test "bounds a large transcript tail and skips partial JSON records", %{path: path, session: session} do
    old_record = Jason.encode!(%{"type" => "user", "message" => %{"content" => String.duplicate("old", 100_000)}})
    recent = Jason.encode!(%{"type" => "user", "message" => %{"content" => "Recent request"}})
    File.write!(path, old_record <> "\n" <> recent <> "\n{\"type\":")
    assert ExecutorTranscript.read_session(session, 10) == {:ok, %{events: [%{role: "user", body: "Recent request"}]}}
  end

  test "missing and unsupported sessions stay unavailable", %{session: session} do
    assert ExecutorTranscript.read_session(session, 10) == {:error, :unavailable}
    assert ExecutorTranscript.read_session(%{session | "harness" => "codex"}, 10) == {:error, :unavailable}
    assert ExecutorTranscript.read_session(%{session | "state" => "unknown"}, 10) == {:error, :unavailable}
  end
end
