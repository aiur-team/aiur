defmodule Aiur.Listener.ModeStoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias Aiur.Listener.ModeStore

  setup do
    dir = Aiur.TestSupport.tmp_root!("listener-mode-store")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{opts: [dir: dir, repo_name: "mode-test"]}
  end

  test "missing record reads as default sync with version 0 and actor default", %{opts: opts} do
    assert ModeStore.get("1", opts) == %{requested: :sync, version: 0, actor: :default, updated_at: nil}
  end

  test "matching expected version persists all modes, metadata and incremented versions", %{opts: opts} do
    for {mode, version} <- Enum.with_index([:sync, :steer, :async], 1) do
      meta = %{actor: :human, idempotency_key: "key-#{version}"}
      assert {:ok, record} = ModeStore.put("1", mode, version - 1, meta, opts)
      assert record.requested == mode
      assert record.version == version
      assert record.actor == :human
      assert record.idempotency_key == meta.idempotency_key
      assert {:ok, _, 0} = DateTime.from_iso8601(record.updated_at)
      assert ModeStore.get("1", opts) == record
    end
  end

  test "stale expected version conflicts with the winning record and leaves disk unchanged", %{opts: opts} do
    assert {:ok, winner} = ModeStore.put("1", :async, 0, %{actor: :executor}, opts)
    assert {:error, {:mode_conflict, ^winner}} = ModeStore.put("1", :steer, 0, %{actor: :human}, opts)
    assert ModeStore.get("1", opts) == winner
  end

  test "same idempotency key and mode returns stored record without a version bump", %{opts: opts} do
    meta = %{actor: :human, idempotency_key: "retry"}
    assert {:ok, record} = ModeStore.put("1", :async, 0, meta, opts)
    path = ModeStore.path_for("1", opts)
    bytes = File.read!(path)
    assert {:ok, ^record} = ModeStore.put("1", :async, 0, %{meta | actor: :system}, opts)
    assert {:ok, ^record} = ModeStore.put("1", :async, 1, meta, opts)
    assert File.read!(path) == bytes
    assert {:error, {:mode_conflict, ^record}} = ModeStore.put("1", :sync, 0, meta, opts)
  end

  test "invalid modes do not create a file", %{opts: opts} do
    assert {:error, :invalid_mode} = ModeStore.put("1", :unknown, 0, %{actor: :human}, opts)
    refute File.exists?(ModeStore.path_for("1", opts))
  end

  test "unknown stored mode decodes to sync, warns once and keeps the file", %{opts: opts} do
    assert {:ok, record} = ModeStore.put("unknown-mode", :async, 0, %{actor: :human}, opts)
    path = ModeStore.path_for("unknown-mode", opts)
    raw = path |> File.read!() |> Jason.decode!() |> Map.put("requested", "future")
    Aiur.JsonStore.write!(path, raw)
    bytes = File.read!(path)

    log =
      capture_log(fn ->
        assert ModeStore.get("unknown-mode", opts) == %{record | requested: :sync}
        assert ModeStore.get("unknown-mode", opts) == %{record | requested: :sync}
      end)

    assert length(Regex.scan(~r/ModeStore\(unknown-mode\) unknown requested mode/, log)) == 1
    assert File.read!(path) == bytes
  end

  test "corrupt, malformed and forward version records fall back without deleting evidence", %{opts: opts} do
    path = ModeStore.path_for("1", opts)
    assert {:ok, _record} = ModeStore.put("1", :async, 0, %{actor: :human}, opts)
    future = path |> File.read!() |> Jason.decode!() |> Map.put("schema_version", 2) |> Jason.encode!()

    for bytes <- ["{broken", "[]", "null", ~s({"schema_version":1,"version":"bad"}), future] do
      File.write!(path, bytes)
      assert ModeStore.get("1", opts) == %{requested: :sync, version: 0, actor: :default, updated_at: nil}
      assert File.read!(path) == bytes
    end
  end

  test "record survives a fresh process reading the same directory", %{opts: opts} do
    record = Task.async(fn -> ModeStore.put("1", :steer, 0, %{actor: :system}, opts) end) |> Task.await()
    assert {:ok, expected} = record
    assert Task.async(fn -> ModeStore.get("1", opts) end) |> Task.await() == expected
  end

  test "write failure returns a structured error and preserves the existing record", %{opts: opts} do
    assert {:ok, record} = ModeStore.put("1", :async, 0, %{actor: :human}, opts)
    File.chmod!(opts[:dir], 0o500)

    try do
      assert {:error, {:write_failed, _reason}} = ModeStore.put("1", :sync, 1, %{actor: :human}, opts)
      assert ModeStore.get("1", opts) == record
    after
      File.chmod!(opts[:dir], 0o700)
    end
  end

  test "clear removes only the sanitized ticket in the selected repository and is idempotent", %{opts: opts} do
    assert {:ok, _} = ModeStore.put("feat/x", :async, 0, %{actor: :human}, opts)
    other = Keyword.put(opts, :repo_name, "other")
    assert {:ok, record} = ModeStore.put("feat/x", :steer, 0, %{actor: :human}, other)
    assert Path.dirname(ModeStore.path_for("feat/x", opts)) == opts[:dir]
    assert :ok = ModeStore.clear("feat/x", opts)
    refute File.exists?(ModeStore.path_for("feat/x", opts))
    assert :ok = ModeStore.clear("feat/x", opts)
    assert ModeStore.get("feat/x", other) == record
  end
end
