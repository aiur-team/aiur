defmodule VoiceConverse.TranscriptStoreTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.TranscriptStore

  @id "vc_" <> String.duplicate("a", 22)
  @started %{target: "worker-1", role_id: "default", provider: "fake"}

  # Each test gets its own root; the store never falls back to a shared or default path.
  setup do
    dir = Path.join(System.tmp_dir!(), "voice_converse_transcripts_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{root: Path.join(dir, "transcripts")}
  end

  defp open!(root, opts \\ []) do
    {:ok, store} = TranscriptStore.open(root, @id, @started, Keyword.put_new(opts, :sync_fs, fn -> :ok end))
    store
  end

  test "append returns only after the record is synced, so the caller never announces an undurable record",
       %{root: root} do
    test_pid = self()
    datasync = fn fd -> send(test_pid, :synced) && :file.datasync(fd) end
    store = open!(root, datasync: datasync)
    assert_received :synced

    assert :ok = TranscriptStore.append(store, %{type: "user_turn", turn_id: "t1", text: "hi"})
    assert_received :synced
  end

  test "a failed sync is reported, not acknowledged", %{root: root} do
    store = open!(root)
    failing = %{store | datasync: fn _fd -> {:error, :eio} end}
    assert {:error, :eio} = TranscriptStore.append(failing, %{type: "user_turn", text: "lost?"})
  end

  test "open runs the filesystem barrier exactly once so the new file entry survives a crash", %{root: root} do
    test_pid = self()
    store = open!(root, sync_fs: fn -> send(test_pid, :fs_synced) && :ok end)
    :ok = TranscriptStore.append(store, %{type: "user_turn", text: "x"})
    assert_received :fs_synced
    refute_received :fs_synced
  end

  test "a failed creation barrier removes the partial file so the id is not blocked", %{root: root} do
    assert {:error, :nope} = TranscriptStore.open(root, @id, @started, sync_fs: fn -> {:error, :nope} end)
    {:ok, path} = TranscriptStore.path(root, @id)
    refute File.exists?(path)
    assert {:ok, _} = TranscriptStore.open(root, @id, @started, sync_fs: fn -> :ok end)
  end

  test "records holding DateTimes (context observed_at) encode instead of crashing the session", %{root: root} do
    at = ~U[2026-10-21 12:00:00Z]
    {:ok, store} = TranscriptStore.open(root, @id, Map.put(@started, :started_at, at), sync_fs: fn -> :ok end)
    :ok = TranscriptStore.append(store, %{type: "context", source: "briefing", observed_at: at, text: "ok"})

    assert {:ok, [%{"started_at" => "2026-10-21T12:00:00Z"}, %{"observed_at" => "2026-10-21T12:00:00Z"}], _} =
             TranscriptStore.read(root, @id)
  end

  test "session_started cannot override the real conversation id", %{root: root} do
    {:ok, _} = TranscriptStore.open(root, @id, Map.put(@started, :conversation_id, "other"), sync_fs: fn -> :ok end)
    assert {:ok, [%{"conversation_id" => @id}], _} = TranscriptStore.read(root, @id)
  end

  test "records round-trip in order with version, type and timestamp", %{root: root} do
    store = open!(root)
    :ok = TranscriptStore.append(store, %{type: "user_turn", turn_id: "t1", text: "status?"})
    :ok = TranscriptStore.append(store, %{"type" => "assistant_turn", "turn_id" => "t1", "text" => "green"})
    :ok = TranscriptStore.close(store)

    assert {:ok, [started, user, assistant], %{torn_tail: false}} = TranscriptStore.read(root, @id)
    assert %{"v" => 1, "type" => "session_started", "conversation_id" => @id, "target" => "worker-1"} = started
    assert {:ok, _, _} = DateTime.from_iso8601(started["at"])
    assert %{"type" => "user_turn", "text" => "status?"} = user
    assert %{"type" => "assistant_turn", "text" => "green"} = assistant
  end

  test "a torn last line (crash mid-write) is reported and skipped, earlier records intact", %{root: root} do
    store = open!(root)
    :ok = TranscriptStore.append(store, %{type: "user_turn", text: "kept"})
    :ok = TranscriptStore.close(store)
    {:ok, path} = TranscriptStore.path(root, @id)
    File.write!(path, ~s({"v":1,"type":"assistant_turn","te), [:append])
    before = File.read!(path)

    assert {:ok, [_started, %{"text" => "kept"}], %{torn_tail: true}} = TranscriptStore.read(root, @id)
    # Review material: the torn bytes are reported, never deleted.
    assert File.read!(path) == before
  end

  test "a newline-terminated but undecodable last line is also a torn tail", %{root: root} do
    store = open!(root)
    :ok = TranscriptStore.close(store)
    {:ok, path} = TranscriptStore.path(root, @id)
    File.write!(path, "{\"v\":1,\n", [:append])

    assert {:ok, [%{"type" => "session_started"}], %{torn_tail: true}} = TranscriptStore.read(root, @id)
  end

  # Boot reconciliation appends session_ended to a crashed transcript; it must not glue onto the
  # torn bytes and make the whole transcript unreadable.
  test "reopen after a torn tail seals it, so later records stay readable", %{root: root} do
    store = open!(root)
    :ok = TranscriptStore.append(store, %{type: "user_turn", text: "kept"})
    :ok = TranscriptStore.close(store)
    {:ok, path} = TranscriptStore.path(root, @id)
    File.write!(path, ~s({"v":1,"type":"assistant_turn","te), [:append])

    {:ok, store} = TranscriptStore.reopen(root, @id)
    :ok = TranscriptStore.append(store, %{type: "session_ended", reason: "daemon_restart"})
    :ok = TranscriptStore.close(store)

    assert {:ok, [_started, %{"text" => "kept"}, %{"type" => "session_ended"}], %{torn_tail: false, skipped_lines: [3]}} =
             TranscriptStore.read(root, @id)

    assert File.read!(path) =~ ~s("te\n)
  end

  test "reopen of a clean transcript adds no blank line", %{root: root} do
    :ok = TranscriptStore.close(open!(root))
    {:ok, store} = TranscriptStore.reopen(root, @id)
    :ok = TranscriptStore.append(store, %{type: "session_ended", reason: "daemon_restart"})

    assert {:ok, [_, %{"type" => "session_ended"}], %{torn_tail: false, skipped_lines: []}} =
             TranscriptStore.read(root, @id)
  end

  test "reopen of a missing transcript is not_found", %{root: root} do
    assert {:error, :not_found} = TranscriptStore.reopen(root, @id)
  end

  test "an existing root readable by others is refused, not chmodded", %{root: root} do
    File.mkdir_p!(root)
    File.chmod!(root, 0o755)
    assert {:error, {:insecure_root, _}} = TranscriptStore.open(root, @id, @started, sync_fs: fn -> :ok end)
    assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o755
  end

  test "a symlinked root is refused", %{root: root} do
    real = root <> "_real"
    File.mkdir_p!(real)
    File.chmod!(real, 0o700)
    File.ln_s!(real, root)
    assert {:error, {:symlink_rejected, _}} = TranscriptStore.open(root, @id, @started, sync_fs: fn -> :ok end)
  end

  test "path traversal ids are refused and nothing is created", %{root: root} do
    for id <- [
          "../x",
          "vc_../../../../etc/passwdxx",
          "vc_" <> String.duplicate("a", 21),
          "vc_" <> String.duplicate("/", 22)
        ] do
      assert {:error, :invalid_conversation_id} = TranscriptStore.open(root, id, @started, sync_fs: fn -> :ok end)
      assert {:error, :invalid_conversation_id} = TranscriptStore.read(root, id)
    end

    refute File.exists?(root)
  end

  test "an unset root is refused; voice never writes to a default path" do
    assert {:error, :invalid_root} = TranscriptStore.open(nil, @id, @started)
    assert {:error, :invalid_root} = TranscriptStore.open("", @id, @started)
  end

  test "audio, key and signed-url records are refused and nothing is written", %{root: root} do
    store = open!(root)

    for record <- [
          %{type: "context", data_b64: "AAAA"},
          %{type: "context", audio: <<0, 1>>},
          %{type: "tool_result", summary: %{"signed_url" => "https://x"}},
          %{type: "tool_call", params: [%{api_key: "sk-x"}]}
        ] do
      assert {:error, {:forbidden_field, _}} = TranscriptStore.append(store, record)
    end

    # A nested `audio` is a name (e.g. a tool parameter), not audio bytes; it must not end a session.
    assert :ok = TranscriptStore.append(store, %{type: "tool_call", params: %{audio: "muted"}})

    :ok = TranscriptStore.close(store)

    assert {:ok, [%{"type" => "session_started"}, %{"type" => "tool_call"}], %{torn_tail: false}} =
             TranscriptStore.read(root, @id)
  end

  test "unknown record types are refused", %{root: root} do
    store = open!(root)
    assert {:error, {:unknown_type, "summary"}} = TranscriptStore.append(store, %{type: "summary", text: "x"})
  end

  test "a second open of the same conversation is refused rather than mixing sessions", %{root: root} do
    open!(root)
    assert {:error, :exists} = TranscriptStore.open(root, @id, @started, sync_fs: fn -> :ok end)
  end

  test "the directory and file are owner-only", %{root: root} do
    open!(root)
    {:ok, path} = TranscriptStore.path(root, @id)
    assert File.stat!(root).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "a missing transcript is not_found", %{root: root} do
    assert {:error, :not_found} = TranscriptStore.read(root, @id)
  end
end
