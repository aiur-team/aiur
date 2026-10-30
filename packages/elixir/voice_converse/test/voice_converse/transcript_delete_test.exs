defmodule VoiceConverse.TranscriptDeleteTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias VoiceConverse.{TestCleanup, TranscriptIndex, Transcripts, TranscriptStore}
  alias VoiceConverse.TranscriptIndex.IndexFile

  @id "vc_aaaaaaaaaaaaaaaaaaaaaa"
  @other "vc_bbbbbbbbbbbbbbbbbbbbbb"

  setup do
    root = Path.join(System.tmp_dir!(), "transcript_delete_#{System.unique_integer([:positive])}")
    on_exit(fn -> TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  test "delete requires the id twice without changing the transcript", %{root: root} do
    ended(root)
    before = File.read!(Path.join(root, @id <> ".ndjson"))

    for opts <- [[], [confirm: @other]] do
      assert {:error, :confirmation_required} = TranscriptStore.delete(root, @id, opts)
    end

    assert File.read!(Path.join(root, @id <> ".ndjson")) == before
    refute File.exists?(Path.join(root, ".deleted"))
  end

  test "an active conversation cannot be deleted", %{root: root} do
    {:ok, store} = TranscriptStore.open(root, @id, %{target: "executor"}, sync_fs: fn -> :ok end)

    try do
      assert {:error, :active_conversation} = TranscriptStore.delete(root, @id, confirm: @id)

      assert capture_io(:stderr, fn -> assert Transcripts.print(root, [@id, "--delete", "--confirm", @id]) == 1 end) ==
               "End the conversation first\n"

      assert :ok = TranscriptStore.append(store, %{type: "user_turn", text: "still here"})
    after
      TranscriptStore.close(store)
    end
  end

  test "deletion leaves only a content-free tombstone and survives index rebuild", %{root: root} do
    ended(root)
    assert :ok = TranscriptStore.delete(root, @id, confirm: @id, by: "operator")
    assert {:error, :not_found} = TranscriptStore.read(root, @id)
    assert {:error, :not_found} = TranscriptIndex.get(root, @id)
    assert {:ok, [], nil} = TranscriptIndex.list(root)
    assert TranscriptIndex.minutes_today(root) == 0
    assert {:ok, [tombstone]} = IndexFile.read(root)
    assert Enum.sort(Map.keys(tombstone)) == [:by, :conversation_id, :deleted_at]
    assert tombstone.by == "operator"
    assert tombstone.conversation_id == @id
    assert {:ok, _, 0} = DateTime.from_iso8601(tombstone.deleted_at)
    refute File.read!(Path.join(root, "index.ndjson")) =~ "private"
    assert File.ls!(Path.join(root, ".deleted")) == [@id <> ".json"]
    File.rm!(Path.join(root, "index.ndjson"))
    assert {:ok, [], nil} = TranscriptIndex.list(root)
    assert {:ok, [^tombstone]} = IndexFile.read(root)
    assert {:ok, %{errors: [], reconciled: 0}} = TranscriptIndex.reconcile(root)
    assert {:ok, [^tombstone]} = IndexFile.read(root)
  end

  test "deleting one session preserves another session and its cap accounting", %{root: root} do
    ended(root)
    ended(root, @other)
    assert :ok = TranscriptStore.delete(root, @id, confirm: @id)
    assert {:ok, [%{conversation_id: @other, duration_s: 60}], nil} = TranscriptIndex.list(root)
    assert {:ok, records, _} = TranscriptStore.read(root, @other)
    assert Enum.any?(records, &(&1["text"] == "private text"))
    assert TranscriptIndex.minutes_today(root) == 1
  end

  test "failed index commit keeps staged transcript until boot recovery", %{root: root} do
    ended(root)
    File.rm!(Path.join(root, "index.ndjson"))
    File.mkdir!(Path.join(root, "index.ndjson"))
    assert {:error, _} = TranscriptStore.delete(root, @id, confirm: @id)
    staged = Path.join([root, ".deleted", @id <> ".ndjson"])
    assert File.read!(staged) =~ "private"
    refute File.exists?(Path.join(root, @id <> ".ndjson"))
    File.rmdir!(Path.join(root, "index.ndjson"))
    assert {:ok, %{errors: [], reconciled: 0}} = TranscriptIndex.reconcile(root)
    refute File.exists?(staged)
    assert {:ok, [%{conversation_id: @id, by: "operator"}]} = IndexFile.read(root)
  end

  test "CLI validates deletion arguments and deletes through the store", %{root: root} do
    ended(root)

    for args <- [
          ["--delete"],
          [@id, "--delete"],
          [@id, "--delete", "--confirm", @other],
          [@id, "--confirm", @id],
          [@id, "--delete", "--confirm", @id, "--json"]
        ] do
      assert capture_io(:stderr, fn -> assert Transcripts.print(root, args) == 64 end) ==
               "Invalid transcript arguments\n"
    end

    assert {:ok, "Deleted conversation " <> @id} = Transcripts.run(root, [@id, "--delete", "--confirm", @id])
    assert {:error, :not_found} = TranscriptStore.read(root, @id)
  end

  test "unsafe ids and symlink staging directory are refused", %{root: root} do
    ended(root)
    assert {:error, :invalid_conversation_id} = TranscriptStore.delete(root, "../escape", confirm: "../escape")
    File.ln_s!(root, Path.join(root, ".deleted"))
    assert {:error, :unsafe_transcript_root} = TranscriptStore.delete(root, @id, confirm: @id)
    assert {:ok, _, _} = TranscriptStore.read(root, @id)
  end

  defp ended(root, id \\ @id) do
    {:ok, store} = TranscriptStore.open(root, id, %{target: "private target"}, sync_fs: fn -> :ok end)
    :ok = TranscriptStore.append(store, %{type: "user_turn", text: "private text"})
    :ok = TranscriptStore.append(store, %{type: "session_ended", reason: "user_end", duration_s: 60})
    :ok = TranscriptStore.close(store)
  end
end
