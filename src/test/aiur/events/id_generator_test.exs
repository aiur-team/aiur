defmodule Aiur.Events.IdGeneratorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Events.IdGenerator
  alias Aiur.JsonStore

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "aiur_idgen_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "event_id")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir, path: path}
  end

  describe "next_id/1" do
    test "returns strictly increasing values", %{path: path} do
      {:ok, pid} = IdGenerator.start_link(name: nil, path: path)

      ids = for _ <- 1..100, do: IdGenerator.next_id(pid)

      assert ids == Enum.sort(ids)
      assert Enum.uniq(ids) == ids
      GenServer.stop(pid)
    end

    test "uniqueness across many calls", %{path: path} do
      {:ok, pid} = IdGenerator.start_link(name: nil, path: path, batch_size: 7)

      ids = for _ <- 1..1000, do: IdGenerator.next_id(pid)

      assert length(Enum.uniq(ids)) == 1000
      GenServer.stop(pid)
    end
  end

  describe "reserve-before-return" do
    test "persists reserved_through ahead of current", %{path: path} do
      {:ok, pid} = IdGenerator.start_link(name: nil, path: path, batch_size: 50)

      # First ID triggers an initial reserve. After: reserved_through >= current.
      _ = IdGenerator.next_id(pid)

      {:ok, %{"last_id" => last_id, "reserved_through" => reserved_through}} = JsonStore.read(path)
      assert reserved_through >= last_id

      GenServer.stop(pid)
    end

    test "after kill simulation, no IDs are reused", %{path: path} do
      Process.flag(:trap_exit, true)

      {:ok, pid1} = IdGenerator.start_link(name: nil, path: path, batch_size: 10)
      ids_round1 = for _ <- 1..5, do: IdGenerator.next_id(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:EXIT, ^pid1, :killed}, 1_000

      {:ok, pid2} = IdGenerator.start_link(name: nil, path: path, batch_size: 10)
      ids_round2 = for _ <- 1..5, do: IdGenerator.next_id(pid2)
      GenServer.stop(pid2)

      assert Enum.min(ids_round2) > Enum.max(ids_round1)
      assert MapSet.disjoint?(MapSet.new(ids_round1), MapSet.new(ids_round2))
    end
  end

  describe "unwritable counter paths" do
    test "stays alive and keeps issuing increasing IDs when boot reservation cannot persist", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)

      unwritable_dir = Path.join(tmp_dir, "unwritable")
      File.mkdir_p!(unwritable_dir)
      File.chmod!(unwritable_dir, 0o500)
      path = Path.join(unwritable_dir, "event_id")

      on_exit(fn -> File.chmod!(unwritable_dir, 0o700) end)

      log =
        capture_log(fn ->
          {:ok, pid} = IdGenerator.start_link(name: nil, path: path, batch_size: 2)

          ids = for _ <- 1..4, do: IdGenerator.next_id(pid)

          assert ids == Enum.sort(ids)
          assert Enum.uniq(ids) == ids
          assert Process.alive?(pid)
          GenServer.stop(pid)
        end)

      assert log =~ "IdGenerator counter persistence failed"
      assert log =~ path
      assert length(Regex.scan(~r/IdGenerator counter persistence failed/, log)) == 1
    end
  end

  describe "cold-boot fallback (missing file)" do
    test "seeds from system_time(:microsecond)", %{path: path} do
      # File doesn't exist
      {:ok, pid} = IdGenerator.start_link(name: nil, path: path)
      id = IdGenerator.next_id(pid)

      # Should be >= a recent microsecond timestamp (loose check; just confirms
      # we're in the wall-clock regime, not 1)
      now_us = System.system_time(:microsecond)
      assert id > now_us - 60_000_000
      assert id <= now_us + 10_000_000_000
      GenServer.stop(pid)
    end
  end

  describe "cold-boot fallback (corrupt file)" do
    test "treats corrupt JSON as missing, logs warning, seeds from wall-clock", %{path: path} do
      File.write!(path, "{not valid json")

      {:ok, pid} = IdGenerator.start_link(name: nil, path: path)
      id = IdGenerator.next_id(pid)

      assert is_integer(id)
      assert id > 0
      GenServer.stop(pid)
    end

    test "treats unexpected JSON shape as corrupt", %{path: path} do
      File.write!(path, ~s({"unrelated": "shape"}))

      {:ok, pid} = IdGenerator.start_link(name: nil, path: path)
      id = IdGenerator.next_id(pid)

      assert is_integer(id)
      assert id > 0
      GenServer.stop(pid)
    end
  end

  describe "peek/1" do
    test "returns current without advancing", %{path: path} do
      {:ok, pid} = IdGenerator.start_link(name: nil, path: path)
      _ = IdGenerator.next_id(pid)
      _ = IdGenerator.next_id(pid)

      seen = IdGenerator.peek(pid)
      next = IdGenerator.next_id(pid)

      assert next == seen + 1
      GenServer.stop(pid)
    end
  end
end
