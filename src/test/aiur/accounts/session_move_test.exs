defmodule Aiur.Accounts.SessionMoveTest do
  use Aiur.TestSupport

  alias Aiur.Accounts
  alias Aiur.Accounts.UsageReadings
  alias Aiur.Claude.RemoteControl

  setup do
    UsageReadings.reset()
    home = Aiur.TestSupport.tmp_root!("aiur-accounts")
    File.mkdir_p!(home)
    previous = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      UsageReadings.reset()
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "moves Claude session artifacts and merges only that session history by timestamp", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    project = RemoteControl.workspace_slug("/repo")
    transcript = Path.join([source, "projects", project, session <> ".jsonl"])
    File.mkdir_p!(Path.dirname(transcript))
    File.write!(transcript, "transcript")

    File.write!(
      Path.join(source, "history.jsonl"),
      Enum.join(
        [
          Jason.encode!(%{"sessionId" => session, "timestamp" => "2026-01-02T00:00:00Z"}),
          Jason.encode!(%{"sessionId" => "other", "timestamp" => "2026-01-01T00:00:00Z"})
        ],
        "\n"
      ) <> "\n"
    )

    File.write!(Path.join(destination, "history.jsonl"), Jason.encode!(%{"sessionId" => "existing", "timestamp" => "2026-01-01T12:00:00Z"}) <> "\n")

    assert :ok = Accounts.move_session("claude", "default", "work", session, "/repo")
    refute File.exists?(transcript)
    assert File.read!(Path.join([destination, "projects", project, session <> ".jsonl"])) == "transcript"
    history = File.read!(Path.join(destination, "history.jsonl")) |> String.split("\n", trim: true)
    assert Enum.map(history, &Jason.decode!/1) |> Enum.map(& &1["sessionId"]) == ["existing", session]
    assert File.read!(Path.join(source, "history.jsonl")) =~ "other"
    refute File.read!(Path.join(source, "history.jsonl")) =~ session
  end

  test "moves a session into the default profile", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    transcript = Path.join([source, "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
    File.mkdir_p!(Path.dirname(transcript))
    File.write!(transcript, "transcript")

    assert :ok = Accounts.move_session("claude", "work", "default", session, "/repo")
    refute File.exists?(transcript)
    assert File.read!(Path.join([home, ".claude", "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])) == "transcript"
  end

  test "skips a destination artifact symlink that resolves to the source file", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    relative = Path.join(["projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
    source_transcript = Path.join(source, relative)
    destination_transcript = Path.join(destination, relative)
    File.mkdir_p!(Path.dirname(source_transcript))
    File.mkdir_p!(Path.dirname(destination_transcript))
    File.write!(source_transcript, "transcript")
    File.ln_s!(source_transcript, destination_transcript)

    assert :ok = Accounts.move_session("claude", "default", "work", session, "/repo")
    assert File.read!(source_transcript) == "transcript"
    assert File.read!(destination_transcript) == "transcript"
    assert File.read_link!(destination_transcript) == source_transcript
  end

  test "reports source deletion failure after a verified cross-filesystem copy", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    session = "11111111-2222-4333-8444-555555555555"
    transcript = Path.join([source, "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
    File.mkdir_p!(Path.dirname(transcript))
    File.write!(transcript, "transcript")
    rm = fn path -> if path == transcript, do: {:error, :injected_delete_failure}, else: File.rm_rf(path) end

    assert {:error, {:source_delete_failed, :injected_delete_failure}} =
             Accounts.move_session("claude", "default", "work", session, "/repo", same_device: false, rm_rf: rm)

    assert File.read!(transcript) == "transcript"
    refute File.exists?(Path.join([home, ".aiur/accounts/claude/work", "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"]))
  end

  test "refuses a live session and a destination that already contains it", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    registry = Path.join(source, "sessions")
    File.mkdir_p!(registry)
    File.write!(Path.join(registry, session <> ".json"), "{}")
    assert {:error, :session_live} = Accounts.move_session("claude", "default", "work", session, "/repo")
    File.rm!(Path.join(registry, session <> ".json"))
    destination_artifact = Path.join([destination, "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
    File.mkdir_p!(Path.dirname(destination_artifact))
    File.write!(destination_artifact, "pre-existing")
    assert {:error, :destination_session_exists} = Accounts.move_session("claude", "default", "work", session, "/repo")
  end

  test "rolls back earlier artifact renames when a later rename fails", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    project = Path.join([source, "projects", RemoteControl.workspace_slug("/repo")])
    File.mkdir_p!(project)
    transcript = Path.join(project, session <> ".jsonl")
    File.write!(transcript, "source")
    file_history = Path.join([source, "file-history", session])
    File.mkdir_p!(file_history)
    File.write!(Path.join(file_history, "snapshot"), "history")
    conflict = Path.join([destination, "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])

    rename = fn from, to ->
      if String.ends_with?(from, session <> ".jsonl"), do: {:error, :injected_failure}, else: File.rename(from, to)
    end

    assert {:error, :injected_failure} = Accounts.move_session("claude", "default", "work", session, "/repo", rename: rename)
    assert File.read!(transcript) == "source"
    assert File.read!(Path.join(file_history, "snapshot")) == "history"
    refute File.exists?(conflict)
  end

  test "copies and verifies the session artifacts before removing the source on another filesystem", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    project = Path.join([source, "projects", RemoteControl.workspace_slug("/repo")])
    File.mkdir_p!(project)
    transcript = Path.join(project, session <> ".jsonl")
    File.write!(transcript, "verified transcript")
    parent = self()

    copy = fn from, to ->
      send(parent, {:copied, from, to})
      File.cp_r(from, to)
    end

    assert :ok = Accounts.move_session("claude", "default", "work", session, "/repo", same_device: false, copy: copy)
    assert_received {:copied, ^transcript, _}
    refute File.exists?(transcript)
    assert File.read!(Path.join([destination, "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])) == "verified transcript"
  end
end
