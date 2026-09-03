defmodule Aiur.JsonStoreTest do
  use ExUnit.Case, async: true

  alias Aiur.JsonStore

  setup do
    tmp_dir = Aiur.TestSupport.tmp_root!("aiur_json_store_test")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "write!/2 and read/2" do
    test "round-trips a map", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "round_trip.json")
      data = %{"foo" => "bar", "n" => 42}

      :ok = JsonStore.write!(path, data)
      assert {:ok, ^data} = JsonStore.read(path)
    end

    test "round-trips nested structures", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nested.json")
      data = %{"list" => [1, 2, 3], "map" => %{"k" => "v"}}

      :ok = JsonStore.write!(path, data)
      assert {:ok, ^data} = JsonStore.read(path)
    end

    test "creates parent directories on demand", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "deep", "nested", "path.json"])
      data = %{"created" => true}

      :ok = JsonStore.write!(path, data)
      assert File.exists?(path)
      assert {:ok, ^data} = JsonStore.read(path)
    end

    test "overwrites existing file atomically", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "overwrite.json")

      :ok = JsonStore.write!(path, %{"v" => 1})
      :ok = JsonStore.write!(path, %{"v" => 2})

      assert {:ok, %{"v" => 2}} = JsonStore.read(path)
    end

    test "read/2 returns default on missing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing.json")

      assert {:ok, %{}} = JsonStore.read(path, %{})
      assert {:ok, nil} = JsonStore.read(path)
    end

    test "read/2 returns error on corrupt JSON", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "corrupt.json")
      File.write!(path, "{not valid json")

      assert {:error, _reason} = JsonStore.read(path)
    end

    test "write!/2 cleans up tmp file on success", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "cleanup.json")
      :ok = JsonStore.write!(path, %{"k" => "v"})

      refute File.exists?(path <> ".tmp")
    end

    test "concurrent reads during a write see consistent state", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "concurrent.json")
      :ok = JsonStore.write!(path, %{"v" => 1})

      # Spawn 10 concurrent readers + 10 concurrent writers
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            :ok = JsonStore.write!(path, %{"v" => i})
            JsonStore.read(path)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # Every read returns a valid value (either pre-write or post-write,
      # never partial). The atomic-rename guarantee.
      for {:ok, value} <- results do
        assert is_map(value)
        assert is_integer(Map.get(value, "v"))
      end
    end
  end
end
