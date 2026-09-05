defmodule Aiur.TestShardTest do
  use ExUnit.Case, async: true

  alias Aiur.TestShard

  # Golden values, shared with `rename_preflight.shard_of` in
  # `scripts/test_rename_preflight.py`. They pin the algorithm: if these move,
  # every CI shard is renumbered and the rename preflight starts reporting a
  # shard the coverage jobs do not use.
  @golden %{
    "test/a_test.exs" => 3,
    "test/e_test.exs" => 3,
    "test/f_test.exs" => 1,
    "test/i_test.exs" => 4,
    "test/t_test.exs" => 2
  }

  describe "shard_of/2" do
    test "matches the golden values the Python preflight also asserts" do
      for {path, expected} <- @golden do
        assert TestShard.shard_of(path, 4) == expected, path
      end
    end

    test "returns a 1-based shard inside the requested range" do
      for index <- 1..500 do
        assert TestShard.shard_of("test/aiur/generated_#{index}_test.exs", 4) in 1..4
      end
    end

    test "depends only on the file's own path" do
      assert TestShard.shard_of("test/aiur/foo_test.exs", 4) ==
               TestShard.shard_of("test/aiur/foo_test.exs", 4)
    end
  end

  describe "stability (the property #2568 is about)" do
    setup do
      %{files: Enum.map(1..300, &"test/aiur/f#{&1}_test.exs")}
    end

    test "inserting a file moves only that file", %{files: files} do
      before = TestShard.assignments(files, 4)
      later = TestShard.assignments(["test/aiur/inserted_test.exs" | files], 4)

      moved = Enum.filter(files, &(before[&1] != later[&1]))

      assert moved == []
    end

    test "deleting a file moves only that file", %{files: files} do
      [removed | rest] = files
      before = TestShard.assignments(files, 4)
      later = TestShard.assignments(rest, 4)

      assert Enum.filter(rest, &(before[&1] != later[&1])) == []
      refute Map.has_key?(later, removed)
    end

    test "the sorted round-robin rule it replaces moves most of the suite", %{files: files} do
      # Guards the premise rather than the fix: if this ever stops holding, the
      # bug is gone and the extra machinery can go with it.
      round_robin = fn list ->
        list |> Enum.sort() |> Enum.with_index() |> Map.new(fn {file, i} -> {file, rem(i, 4) + 1} end)
      end

      before = round_robin.(files)
      later = round_robin.(["test/aiur/aaa_inserted_test.exs" | files])

      moved = Enum.filter(files, &(before[&1] != later[&1]))

      assert length(moved) > div(length(files), 2)
    end
  end

  describe "select/3 and assignments/2" do
    test "every file lands in exactly one shard" do
      files = Enum.map(1..200, &"test/aiur/s#{&1}_test.exs")

      selected = Enum.flat_map(1..4, &TestShard.select(files, &1, 4))

      assert Enum.sort(selected) == Enum.sort(files)
      assert length(selected) == length(files)
    end

    test "assignments/2 covers every file" do
      files = ["test/a_test.exs", "test/b_test.exs"]

      assert files |> TestShard.assignments(4) |> Map.keys() |> Enum.sort() == files
    end
  end

  describe "discover/1" do
    test "keeps files matching the load filters and drops the rest" do
      tmp = tmp_dir()
      write(tmp, "test/aiur/kept_test.exs")
      write(tmp, "test/support/helper.exs")
      write(tmp, "test/aiur/not_a_test.ex")

      assert TestShard.discover(test_paths: [Path.join(tmp, "test")]) ==
               [Path.join(tmp, "test/aiur/kept_test.exs")]
    end

    test "honours a custom :test_paths" do
      tmp = tmp_dir()
      write(tmp, "integration/one_test.exs")
      write(tmp, "test/two_test.exs")

      assert TestShard.discover(test_paths: [Path.join(tmp, "integration")]) ==
               [Path.join(tmp, "integration/one_test.exs")]
    end

    test "honours a custom :test_load_filters" do
      tmp = tmp_dir()
      write(tmp, "test/one_test.exs")
      write(tmp, "test/two_check.exs")

      assert TestShard.discover(test_paths: [Path.join(tmp, "test")], test_load_filters: [~r/_check\.exs$/]) ==
               [Path.join(tmp, "test/two_check.exs")]
    end

    test "the real project's discovery agrees with a plain wildcard" do
      # The shard set must be the set mix would load. If someone introduces a
      # `:test_pattern` or `:test_load_filters` override, this fails and forces
      # a look at whether the shard rule still sees the same files.
      wildcard = "test" |> Path.join("**/*_test.exs") |> Path.wildcard() |> Enum.sort()

      assert TestShard.discover() == wildcard
      assert wildcard != []
    end
  end

  # Deliberately no `File.cd!/1`: the suite runs async, and a process-global
  # working-directory change would corrupt unrelated tests.
  defp tmp_dir do
    tmp = Path.join(System.tmp_dir!(), "aiur-test-shard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end

  defp write(tmp, relative) do
    path = Path.join(tmp, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end
end
