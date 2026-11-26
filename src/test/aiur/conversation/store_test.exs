defmodule Aiur.Conversation.StoreTest do
  use ExUnit.Case, async: true

  alias Aiur.Conversation.{Ref, Store}
  alias Aiur.TrackerIdentity

  defmodule CountingFile do
    @moduledoc false
    @spec write(term(), iodata()) :: :ok | {:error, term()}
    def write(fd, bytes) do
      send(self(), {:batch_write, IO.iodata_length(bytes)})
      :file.write(fd, bytes)
    end

    @spec sync(term()) :: :ok | {:error, term()}
    def sync(fd) do
      send(self(), :batch_sync)
      :file.sync(fd)
    end
  end

  defmodule FullDisk do
    @moduledoc false
    @spec write(term(), binary()) :: {:error, :enospc}
    def write(fd, bytes) do
      :ok = :file.write(fd, binary_part(bytes, 0, 7))
      {:error, :enospc}
    end

    @spec sync(term()) :: :ok | {:error, term()}
    def sync(fd), do: :file.sync(fd)
  end

  defmodule FailedSync do
    @spec write(term(), iodata()) :: :ok | {:error, term()}
    def write(fd, bytes), do: :file.write(fd, bytes)
    @spec sync(term()) :: {:error, :eio}
    def sync(_fd), do: {:error, :eio}
  end

  defmodule PartialBatch do
    @spec write(term(), binary()) :: {:error, :enospc}
    def write(fd, bytes) do
      {newline, 1} = :binary.match(bytes, "\n")
      :ok = :file.write(fd, binary_part(bytes, 0, newline + 5))
      {:error, :enospc}
    end

    @spec sync(term()) :: :ok | {:error, term()}
    def sync(fd), do: :file.sync(fd)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "conversation-store-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    {:ok, dir: Path.join(root, "conversation"), root: root}
  end

  test "a batch of 50 entries uses one write and one fsync", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    entries = Enum.map(1..50, &entry/1)
    assert {:ok, updated} = Store.append_entries(dir, head, entries, file_ops: CountingFile)
    assert_receive {:batch_write, bytes}, 1000
    assert bytes == byte_size(encoded(entries))
    assert_receive :batch_sync, 1000
    refute_receive {:batch_write, _}, 10
    refute_receive :batch_sync, 10
    assert updated["last_pos"] == 50
    assert File.read!(Store.segment_path(dir, 1)) == encoded(entries)
  end

  test "rolls before the next batch exceeds the segment bound and preserves the first segment", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    first = entry(1, String.duplicate("a", 600))
    second = entry(2, String.duplicate("b", 600))
    assert {:ok, head} = Store.append_entries(dir, head, [first], segment_bytes: 1024)
    first_bytes = File.read!(Store.segment_path(dir, 1))
    assert {:ok, head} = Store.append_entries(dir, head, [second], segment_bytes: 1024)
    assert Enum.map(head["segments"], &{&1["n"], &1["first_pos"], &1["last_pos"]}) == [{1, 1, 1}, {2, 2, 2}]
    assert File.read!(Store.segment_path(dir, 1)) == first_bytes
    assert File.read!(Store.segment_path(dir, 2)) == encoded([second])
  end

  test "rejects an oversized batch without writing entries", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    assert {:error, :batch_too_large} = Store.append_entries(dir, head, [entry(1, String.duplicate("x", 1024))], segment_bytes: 1024)
    refute File.exists?(Store.segment_path(dir, 1))
    assert {:ok, ^head} = Store.read_head(dir)
  end

  test "missing and malformed head caches are rebuilt identically", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    assert {:ok, expected} = Store.append_entries(dir, head, [entry(1), entry(2)])
    File.rm!(Path.join(dir, "head.json"))
    assert {:ok, ^expected} = Store.read_head(dir)
    File.write!(Path.join(dir, "head.json"), "not json")
    assert {:ok, ^expected} = Store.read_head(dir)
    assert Jason.decode!(File.read!(Path.join(dir, "head.json"))) == expected
  end

  test "a valid JSON cache behind the segment bytes is rebuilt", %{dir: dir} do
    assert {:ok, empty} = Store.prepare(dir)
    assert {:ok, head} = Store.append_entries(dir, empty, [entry(1)])
    File.write!(Store.segment_path(dir, 1), encoded([entry(2)]), [:append])
    assert {:ok, rebuilt} = Store.read_head(dir)
    assert rebuilt["last_pos"] == 2
    assert hd(rebuilt["segments"])["bytes"] > hd(head["segments"])["bytes"]
  end

  test "stream ranges include both endpoints across segments", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    entries = Enum.map(1..3, &entry(&1, String.duplicate("x", 600)))

    Enum.reduce(entries, head, fn row, state ->
      assert {:ok, next} = Store.append_entries(dir, state, [row], segment_bytes: 1024)
      next
    end)

    assert {:ok, stream} = Store.stream_entries(dir, 2, 3)
    assert Enum.to_list(stream) == Enum.drop(entries, 1)
    assert {:ok, stream} = Store.stream_entries(dir, 3, :infinity)
    assert Enum.to_list(stream) == [List.last(entries)]
    assert {:ok, stream} = Store.stream_entries(dir, 4, 9)
    assert Enum.to_list(stream) == []
  end

  test "range reads do not replay a non-overlapping segment", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    assert {:ok, head} = Store.append_entries(dir, head, [entry(1, String.duplicate("a", 600))], segment_bytes: 1024)
    second = entry(2, String.duplicate("b", 600))
    assert {:ok, _head} = Store.append_entries(dir, head, [second], segment_bytes: 1024)
    first_path = Store.segment_path(dir, 1)
    original = File.read!(first_path)
    # Keep the byte count equal so the head remains current; only replaying
    # this segment would discover its corruption.
    File.write!(first_path, String.duplicate("x", byte_size(original) - 1) <> "\n")
    assert {:ok, stream} = Store.stream_entries(dir, 2, 2)
    assert Enum.to_list(stream) == [second]
    assert {:error, {:corrupt, "entries.000001.jsonl", 1}} = Store.rebuild_head(dir)
  end

  test "a torn final tail is removed without changing the acknowledged prefix", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    assert {:ok, expected} = Store.append_entries(dir, head, [entry(1)])
    path = Store.segment_path(dir, 1)
    prefix = File.read!(path)
    File.write!(path, ~s({"v":1,"pos":2), [:append])
    assert {:ok, ^expected} = Store.rebuild_head(dir)
    assert File.read!(path) == prefix
  end

  test "an incomplete older segment is corruption and is never truncated", %{dir: dir} do
    assert {:ok, _head} = Store.prepare(dir)
    first = encoded([entry(1)]) <> "torn"
    File.write!(Store.segment_path(dir, 1), first)
    File.write!(Store.segment_path(dir, 2), encoded([entry(2)]))
    assert {:error, {:corrupt, "entries.000001.jsonl", 2}} = Store.rebuild_head(dir)
    assert File.read!(Store.segment_path(dir, 1)) == first
  end

  test "interior corruption is refused without rewriting the segment", %{dir: dir} do
    assert {:ok, _head} = Store.prepare(dir)
    bytes = encoded([entry(1)]) <> "not json\n" <> encoded([entry(3)])
    File.write!(Store.segment_path(dir, 1), bytes)
    assert {:error, {:corrupt, "entries.000001.jsonl", 2}} = Store.rebuild_head(dir)
    assert File.read!(Store.segment_path(dir, 1)) == bytes
  end

  test "replay rejects duplicate positions across segment boundaries", %{dir: dir} do
    assert {:ok, _head} = Store.prepare(dir)
    File.write!(Store.segment_path(dir, 1), encoded([entry(2)]))
    File.write!(Store.segment_path(dir, 2), encoded([entry(2)]))
    assert {:error, {:corrupt, "entries.000002.jsonl", 1}} = Store.rebuild_head(dir)
  end

  test "append rejects non-increasing positions and invalid versions", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    assert {:ok, head} = Store.append_entries(dir, head, [entry(2)])
    path = Store.segment_path(dir, 1)
    original = File.read!(path)

    for rows <- [[entry(2)], [entry(4), entry(3)], [%{"v" => 2, "pos" => 3}], [%{"v" => 1, "pos" => "3"}]] do
      assert {:error, :invalid_position} = Store.append_entries(dir, head, rows)
      assert File.read!(path) == original
    end
  end

  test "disk full returns enospc and leaves a recoverable unacknowledged tail", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    assert {:ok, head} = Store.append_entries(dir, head, [entry(1)])
    path = Store.segment_path(dir, 1)
    prefix = File.read!(path)
    assert {:error, :enospc} = Store.append_entries(dir, head, [entry(2)], file_ops: FullDisk)
    assert byte_size(File.read!(path)) == byte_size(prefix) + 7
    assert {:ok, ^head} = Store.rebuild_head(dir)
    assert File.read!(path) == prefix
    assert {:ok, updated} = Store.append_entries(dir, head, [entry(2)])
    assert updated["last_pos"] == 2
  end

  test "sessions and anchors append verbatim and session sequence survives rebuilding", %{dir: dir} do
    assert {:ok, _head} = Store.prepare(dir)
    sessions = [%{"v" => 1, "session_seq" => 1, "type" => "start"}, %{"v" => 1, "session_seq" => 1, "type" => "end"}, %{"v" => 1, "session_seq" => 2, "type" => "start"}]
    anchors = [%{"v" => 1, "entry_id" => "ent_one"}, %{"v" => 1, "entry_id" => "ent_two"}]
    for row <- sessions, do: assert(:ok = Store.append_session_line(dir, row))
    for row <- anchors, do: assert(:ok = Store.append_anchor_line(dir, row))
    assert File.read!(Path.join(dir, "sessions.jsonl")) == encoded(sessions)
    assert File.read!(Path.join(dir, "anchors.jsonl")) == encoded(anchors)
    assert {:ok, head} = Store.read_head(dir)
    assert head["last_session_seq"] == 2
    assert :ok = Store.append_session_line(dir, %{"v" => 1, "session_seq" => 3})
    assert {:ok, head} = Store.read_head(dir)
    assert head["last_session_seq"] == 3
  end

  test "directories are 0700 and all conversation files are 0600", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir, Ref.executor())
    assert {:ok, _head} = Store.append_entries(dir, head, [entry(1)])
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700

    for name <- ["sessions.jsonl", "anchors.jsonl", "subject.json", "head.json", "entries.000001.jsonl"] do
      assert Bitwise.band(File.stat!(Path.join(dir, name)).mode, 0o777) == 0o600
    end
  end

  test "torn side journals are refused without changing their bytes", %{dir: dir} do
    assert {:ok, _head} = Store.prepare(dir)
    session = %{"v" => 1, "session_seq" => 1}
    anchor = %{"v" => 1, "entry_id" => "ent_one"}
    assert :ok = Store.append_session_line(dir, session)
    assert :ok = Store.append_anchor_line(dir, anchor)

    for name <- ["sessions.jsonl", "anchors.jsonl"] do
      File.write!(Path.join(dir, name), "torn", [:append])
    end

    session_bytes = File.read!(Path.join(dir, "sessions.jsonl"))
    anchor_bytes = File.read!(Path.join(dir, "anchors.jsonl"))
    assert {:error, {:corrupt, "sessions.jsonl", 2}} = Store.rebuild_head(dir)
    assert {:error, {:corrupt, "sessions.jsonl", 2}} = Store.append_session_line(dir, %{"v" => 1, "session_seq" => 2})
    assert {:error, {:corrupt, "anchors.jsonl", 2}} = Store.append_anchor_line(dir, %{"v" => 1, "entry_id" => "ent_two"})
    assert File.read!(Path.join(dir, "sessions.jsonl")) == session_bytes
    assert File.read!(Path.join(dir, "anchors.jsonl")) == anchor_bytes
  end

  test "an empty final segment survives recovery as a stable cache and can accept the next entry", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    assert {:ok, _head} = Store.append_entries(dir, head, [entry(1)])
    File.write!(Store.segment_path(dir, 2), "")
    assert {:ok, recovered} = Store.rebuild_head(dir)
    assert List.last(recovered["segments"]) == %{"n" => 2, "first_pos" => nil, "last_pos" => 1, "bytes" => 0}
    cache_inode = File.stat!(Path.join(dir, "head.json")).inode
    assert {:ok, ^recovered} = Store.read_head(dir)
    assert File.stat!(Path.join(dir, "head.json")).inode == cache_inode
    assert {:ok, stream} = Store.stream_entries(dir, 1, :infinity)
    assert Enum.to_list(stream) == [entry(1)]
    assert {:ok, resumed} = Store.append_entries(dir, recovered, [entry(2)])
    assert List.last(resumed["segments"])["first_pos"] == 2
    assert File.read!(Store.segment_path(dir, 2)) == encoded([entry(2)])
  end

  test "subject creation is immutable and rejects another conversation identity", %{dir: dir} do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_one", "number" => 1}, {"Owner", "Repo"}, {"Owner", "Repo"})
    assert {:ok, ref} = Ref.worker(identity)
    assert {:ok, _head} = Store.prepare(dir, ref)
    path = Path.join(dir, "subject.json")
    original = File.read!(path)
    subject = Jason.decode!(original)
    assert subject["provider_id"] == "I_one"
    assert subject["identifier"] == "1"
    assert subject["conversation_id"] == Ref.conversation_id(ref)
    assert {:ok, renamed} = Ref.worker(%{identity | identifier: "99"})
    assert {:ok, _head} = Store.prepare(dir, renamed)
    assert File.read!(path) == original
    assert {:error, :subject_mismatch} = Store.prepare(dir, Ref.executor())
    assert File.read!(path) == original
  end

  test "symlinked directory components are rejected without modifying the target", %{root: root} do
    real = Path.join(root, "real")
    File.mkdir_p!(real)
    link = Path.join(root, "link")
    File.ln_s!(real, link)
    assert {:error, {:symlink_rejected, ^link}} = Store.prepare(Path.join(link, "conversation"))
    assert File.ls!(real) == []
  end

  test "symlinked files are refused by every read and append surface", %{dir: dir, root: root} do
    assert {:ok, head} = Store.prepare(dir)
    target = Path.join(root, "outside")
    File.write!(target, "untouched")
    link = Path.join(dir, "entries.000001.jsonl")
    File.ln_s!(target, link)
    assert {:error, {:symlink_rejected, ^link}} = Store.read_head(dir)
    assert {:error, {:symlink_rejected, ^link}} = Store.rebuild_head(dir)
    assert {:error, {:symlink_rejected, ^link}} = Store.append_entries(dir, head, [entry(1)])
    assert {:error, {:symlink_rejected, ^link}} = Store.append_session_line(dir, %{"v" => 1, "session_seq" => 1})
    assert {:error, {:symlink_rejected, ^link}} = Store.append_anchor_line(dir, %{"v" => 1})
    assert File.read!(target) == "untouched"
  end

  test "future-regression guard: the store exports no rewrite or deletion API" do
    exports = Store.__info__(:functions) |> Enum.map(&elem(&1, 0))
    for forbidden <- [:delete, :truncate, :rewrite, :put_entry], do: refute(forbidden in exports)
  end

  test "recovery syncs complete uncertain writes before publishing their positions", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    assert {:error, :eio} = Store.append_entries(dir, head, [entry(1)], file_ops: FailedSync)
    assert Jason.decode!(File.read!(Path.join(dir, "head.json")))["last_pos"] == 0
    assert {:error, :eio} = Store.rebuild_head(dir, file_ops: FailedSync)
    assert Jason.decode!(File.read!(Path.join(dir, "head.json")))["last_pos"] == 0
    assert {:ok, recovered} = Store.rebuild_head(dir, file_ops: CountingFile)
    assert_receive :batch_sync, 1000
    assert_receive :batch_sync, 1000
    refute_receive :batch_sync, 10
    assert recovered["last_pos"] == 1
    assert {:ok, updated} = Store.append_entries(dir, recovered, [entry(2)])
    assert updated["last_pos"] == 2
    assert File.read!(Store.segment_path(dir, 1)) == encoded([entry(1), entry(2)])
  end

  test "a partial batch preserves complete rows and removes only its torn final row", %{dir: dir} do
    assert {:ok, head} = Store.prepare(dir)
    assert {:ok, head} = Store.append_entries(dir, head, [entry(1)])
    assert {:error, :enospc} = Store.append_entries(dir, head, [entry(2), entry(3)], file_ops: PartialBatch)
    assert Jason.decode!(File.read!(Path.join(dir, "head.json")))["last_pos"] == 1
    assert {:ok, recovered} = Store.rebuild_head(dir)
    assert recovered["last_pos"] == 2
    assert File.read!(Store.segment_path(dir, 1)) == encoded([entry(1), entry(2)])
    assert {:ok, _updated} = Store.append_entries(dir, recovered, [entry(3)])
    assert File.read!(Store.segment_path(dir, 1)) == encoded([entry(1), entry(2), entry(3)])
  end

  test "failed subject creation never publishes partial immutable metadata", %{dir: dir} do
    assert {:error, :enospc} = Store.prepare(dir, Ref.executor(), file_ops: FullDisk)
    refute File.exists?(Path.join(dir, "subject.json"))
    assert File.ls!(dir) == []
    assert {:error, :eio} = Store.prepare(dir, Ref.executor(), file_ops: FailedSync)
    refute File.exists?(Path.join(dir, "subject.json"))
    assert {:ok, _head} = Store.prepare(dir, Ref.executor())
    assert Jason.decode!(File.read!(Path.join(dir, "subject.json")))["kind"] == "executor"
  end

  defp entry(pos, body \\ "message"), do: %{"v" => 1, "pos" => pos, "kind" => "message", "role" => "agent", "body" => body}
  defp encoded(rows), do: Enum.map_join(rows, "", &(Jason.encode!(&1) <> "\n"))
end
