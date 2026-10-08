defmodule Aiur.BuildQueue.StoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.BuildQueue.{Model, Store}
  alias Aiur.BuildQueue.Model.{Edge, Intent, Item, Latch, Queue}

  @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

  setup do
    root = Path.join(System.tmp_dir!(), "build-queue-store-#{System.unique_integer([:positive])}")
    previous = Application.fetch_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, root)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :decision_state_dir, value)
        :error -> Application.delete_env(:aiur, :decision_state_dir)
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root, path: Path.join([root, "build-queue", "queue.json"])}
  end

  test "missing file loads empty without writing", %{path: path} do
    assert Store.load() == {:ok, @empty}
    refute File.exists?(path)
  end

  test "round-trips a saved document with queue order, edges, intents and latches", %{path: path} do
    time = ~U[2026-10-07 12:34:56.123456Z]

    document = %{
      queues: [%Queue{id: "q-ab12", name: "Release", kind: :list, root: nil, held: true, generation: 2, created_at: time}],
      items: [
        %Item{issue_id: "12", queue_id: "q-ab12", position: 0, hold: :operator, override: nil, promoted_at: nil, added_at: time},
        %Item{issue_id: "13", queue_id: "q-ab12", position: 1, hold: nil, override: :manual_promotion, promoted_at: time, added_at: time}
      ],
      edges: [%Edge{prerequisite: "12", dependent: "13", source: :list}],
      intents: [%Intent{id: "intent-1", issue_id: "13", action: :promote, target_labels: ["agent:todo"], recorded_at_ms: 123, outcome: {:error, :denied}}],
      latches: [%Latch{key: {:prerequisite_failed, "12"}, opened_at_ms: 123}]
    }

    assert Store.save(document) == :ok
    assert Jason.decode!(File.read!(path)) == Model.encode(document)
    assert Store.load() == {:ok, document}

    assert Store.save(@empty) == :ok
    assert Store.load() == {:ok, @empty}
  end

  test "corrupt file loads as read_failed and is not overwritten", %{path: path} do
    bytes = "{broken JSON"
    write_file(path, bytes)

    capture_log(fn -> assert {:error, {:read_failed, %Jason.DecodeError{}}} = Store.load() end)
    assert File.read!(path) == bytes
  end

  test "version 2 file is read_failed and preserved", %{path: path} do
    bytes = Jason.encode!(Map.put(Model.encode(@empty), "version", 2))
    write_file(path, bytes)

    capture_log(fn -> assert Store.load() == {:error, {:read_failed, {:unsupported_version, 2}}} end)
    assert File.read!(path) == bytes
  end

  test "invalid field is read_failed and preserved", %{path: path} do
    bytes = Jason.encode!(Map.put(Model.encode(@empty), "queues", "invalid"))
    write_file(path, bytes)

    capture_log(fn -> assert Store.load() == {:error, {:read_failed, {:invalid, ["queues"]}}} end)
    assert File.read!(path) == bytes
  end

  test "filesystem read errors do not become empty state", %{path: path} do
    File.mkdir_p!(path)
    capture_log(fn -> assert Store.load() == {:error, {:read_failed, :eisdir}} end)
    assert File.dir?(path)
  end

  test "unavailable identity fails load and save", %{root: root} do
    previous = System.get_env("AIUR_INSTANCE_KEY")

    on_exit(fn ->
      if previous, do: System.put_env("AIUR_INSTANCE_KEY", previous), else: System.delete_env("AIUR_INSTANCE_KEY")
    end)

    Application.delete_env(:aiur, :decision_state_dir)
    System.delete_env("AIUR_INSTANCE_KEY")

    capture_log(fn -> assert Store.load() == {:error, {:read_failed, :missing_instance_key}} end)
    assert Store.save(@empty) == {:error, {:path_unavailable, :missing_instance_key}}
    refute File.exists?(root)
  end

  test "failed write returns an error and preserves the obstructing file", %{root: root, path: path} do
    File.mkdir_p!(root)
    bytes = "not a directory"
    File.write!(Path.dirname(path), bytes)

    capture_log(fn -> assert {:error, {:write_failed, File.Error, _}} = Store.save(@empty) end)
    assert File.read!(Path.dirname(path)) == bytes
    refute File.exists?(path)
  end

  defp write_file(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end
end
