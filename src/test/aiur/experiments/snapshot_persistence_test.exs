defmodule Aiur.Experiments.SnapshotPersistenceTest do
  use ExUnit.Case, async: false

  alias Aiur.Experiments.{Evidence, Journal, Paths, Snapshot, SnapshotPersistence}

  setup do
    root = Path.join(System.tmp_dir!(), "snapshot-persistence-#{System.unique_integer([:positive])}")
    previous = Application.fetch_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    unless Process.whereis(Aiur.PubSub), do: start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :experiments_dir, value)
        :error -> Application.delete_env(:aiur, :experiments_dir)
      end

      Aiur.TestCleanup.rm_rf!(root)
    end)

    :ok
  end

  test "committing a different snapshot at an existing revision refuses replacement and preserves exact bytes" do
    id = "write-once"
    original = snapshot(id, 3)
    path = Paths.file(id, "snapshots/before.r1.json")
    assert :ok = SnapshotPersistence.commit(id, "before", original, [])
    bytes = File.read!(path)
    assert {:ok, entries} = Journal.read(Paths.file(id, "journal.ndjson"))

    assert :ok = SnapshotPersistence.commit(id, "before", original, [])
    assert File.read!(path) == bytes
    assert {:ok, ^entries} = Journal.read(Paths.file(id, "journal.ndjson"))

    replacement = snapshot(id, 7)
    refute replacement["sha256"] == original["sha256"]
    assert {:error, :tampered} = SnapshotPersistence.commit(id, "before", replacement, [])
    assert File.read!(path) == bytes
    assert {:ok, ^original} = Snapshot.read(path)
    assert {:ok, ^entries} = Journal.read(Paths.file(id, "journal.ndjson"))
  end

  defp snapshot(id, value) do
    data = %{
      "schema_version" => 1,
      "experiment_id" => id,
      "window_name" => "before",
      "revision" => 1,
      "computed_at" => "2026-10-02T00:00:00Z",
      "observation_count" => 1,
      "metrics" => %{"app/latency" => %{"observations" => [%{"unit_id" => "one", "value" => value}]}}
    }

    Map.put(data, "sha256", Evidence.hash(data))
  end
end
