defmodule Aiur.TestShard do
  @moduledoc """
  Content-stable assignment of ExUnit test files to CI coverage shards.

  `mix test --partitions N` assigns shards round-robin over the *sorted* file
  list (`rem(index, N)`), so the shard of every file is a function of how many
  files sort before it. Adding one test file therefore renumbers every file
  after it: a measured insertion moved 159 files in and out of shard 2 alone.
  The practical consequence is that a green `main` stops predicting a green
  PR — an unrelated diff inherits a fresh test layout, trips a pre-existing
  order-dependent fragility, and the red lands on a module the author never
  touched (#2568).

  This module assigns each file independently of every other file:

      shard(file) = rem(sha256(file) first 8 bytes, shards) + 1

  Because the key depends only on the file's own path, inserting, deleting, or
  renaming a file moves *that* file and nothing else. Grouping is therefore
  stable across branches, which is what makes a shard failure attributable.

  ## Why SHA-256 of the path

  The key must be reproducible outside the BEAM: `scripts/rename_preflight.py`
  reports the CI shard for every hit, and a preflight that disagrees with CI is
  worse than no preflight. SHA-256 is byte-identical in Python, in the shell,
  and here, whereas `:erlang.phash2/1` is a BEAM-internal function with no
  portable definition.

  The hashed key is the **`src/`-relative** test path with forward slashes
  (`test/aiur/foo_test.exs`). Any other implementation must hash exactly that
  string; `scripts/check-test-shard-parity.sh` enforces it in CI.

  ## Balance

  Independent per-file hashing gives up round-robin's exact-count guarantee: the
  counts are binomial around `total / shards` rather than equal. Any rule that
  restores exact balance has to consider the other files, which is precisely the
  property that causes the churn, so the imbalance is the price of the fix.
  Measured shard sizes are printed by `make coverage-partition` on every run.
  """

  @default_test_paths ["test"]
  @default_test_pattern "*.{ex,exs}"

  @typedoc "A `src/`-relative test file path, e.g. `test/aiur/foo_test.exs`."
  @type test_file :: String.t()

  @doc """
  Returns every test file `mix test` would load, sorted.

  Mirrors `Mix.Tasks.Test`'s own discovery so the shard set cannot silently
  diverge from the set mix runs: files matching `:test_pattern` under
  `:test_paths`, kept when they match `:test_load_filters`.
  """
  @spec discover(keyword()) :: [test_file()]
  def discover(project \\ Mix.Project.config()) do
    paths = project[:test_paths] || @default_test_paths
    pattern = project[:test_pattern] || @default_test_pattern
    load_filters = project[:test_load_filters] || [&String.ends_with?(&1, "_test.exs")]

    paths
    |> Enum.flat_map(&Path.wildcard("#{&1}/**/#{pattern}"))
    |> Enum.uniq()
    |> Enum.filter(&any_filter_matches?(&1, load_filters))
    |> Enum.sort()
  end

  @doc """
  Returns the 1-based shard `file` belongs to out of `shards`.

  Depends only on `file`, never on the rest of the suite.
  """
  @spec shard_of(test_file(), pos_integer()) :: pos_integer()
  def shard_of(file, shards) when is_binary(file) and is_integer(shards) and shards > 0 do
    <<key::unsigned-big-integer-size(64), _rest::binary>> = :crypto.hash(:sha256, file)
    rem(key, shards) + 1
  end

  @doc """
  Filters `files` down to the members of `shard` (1-based) out of `shards`.
  """
  @spec select([test_file()], pos_integer(), pos_integer()) :: [test_file()]
  def select(files, shard, shards)
      when is_integer(shard) and is_integer(shards) and shards > 0 and shard in 1..shards//1 do
    Enum.filter(files, &(shard_of(&1, shards) == shard))
  end

  @doc """
  Maps every file in `files` to its shard, as a `%{file => shard}` map.
  """
  @spec assignments([test_file()], pos_integer()) :: %{test_file() => pos_integer()}
  def assignments(files, shards) when is_integer(shards) and shards > 0 do
    Map.new(files, &{&1, shard_of(&1, shards)})
  end

  # Mirrors Mix.Tasks.Test's `any_file_matches?/2`.
  defp any_filter_matches?(file, filters) do
    Enum.any?(filters, fn
      %Regex{} = regex -> Regex.match?(regex, file)
      filter when is_function(filter, 1) -> filter.(file)
      filter when is_binary(filter) -> file == filter
    end)
  end
end
