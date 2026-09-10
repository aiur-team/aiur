defmodule Mix.Tasks.Aiur.TestShard do
  use Mix.Task

  alias Aiur.TestShard

  @shortdoc "List the test files belonging to one content-stable coverage shard"

  @moduledoc """
  Prints the test files assigned to one CI coverage shard.

      mix aiur.test_shard --shard 2 --shards 4
      mix aiur.test_shard --shard 2 --shards 4 --output files.txt
      mix aiur.test_shard --shards 4 --map

  Sharding is content-stable: a file's shard is derived from its own path
  (`Aiur.TestShard`), so adding a test file moves that file alone instead of
  renumbering the whole suite the way `mix test --partitions` does (#2568).

  ## Options

    * `--shard` - 1-based shard to list. Required unless `--map` is given.
    * `--shards` - total shard count. Required.
    * `--output` - write the list to this file instead of standard output.
      Preferred in scripts: compiler output cannot be mistaken for a filename.
    * `--map` - print every file as `shard<TAB>path`, for cross-implementation
      parity checks and for reporting shard balance.
    * `--counts` - print `shard<TAB>count` for every shard.

  Exits non-zero when the requested shard resolves to zero files: an empty list
  handed to `mix test` silently runs the *entire* suite, which would turn a
  discovery bug into a four-times-duplicated CI run rather than a red.

  Also refuses to emit a path containing whitespace. The shard runner in
  `src/Makefile` word-splits this list deliberately (`xargs` would remap a test
  failure's exit status onto the code CI reads as a timeout), so a path that
  cannot survive word-splitting has to fail here rather than silently run the
  wrong files.
  """

  @switches [shard: :integer, shards: :integer, output: :string, map: :boolean, counts: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    invalid == [] || Mix.raise("aiur.test_shard: unrecognised options #{inspect(invalid)}")

    shards = opts[:shards] || Mix.raise("aiur.test_shard: --shards is required")
    shards > 0 || Mix.raise("aiur.test_shard: --shards must be positive, got: #{shards}")

    files = TestShard.discover()

    files != [] ||
      Mix.raise("aiur.test_shard: no test files discovered under #{inspect(Mix.Project.config()[:test_paths] || ["test"])}")

    reject_unsplittable_paths(files)

    lines = lines(opts, files, shards)
    emit(opts[:output], lines)
  end

  defp reject_unsplittable_paths(files) do
    case Enum.filter(files, &String.match?(&1, ~r/\s/)) do
      [] ->
        :ok

      offenders ->
        Mix.raise(
          "aiur.test_shard: the shard runner word-splits this list, so a test path may not contain whitespace: " <>
            Enum.map_join(offenders, ", ", &inspect/1)
        )
    end
  end

  defp lines(opts, files, shards) do
    cond do
      opts[:map] ->
        Enum.map(files, &"#{TestShard.shard_of(&1, shards)}\t#{&1}")

      opts[:counts] ->
        counts = Enum.frequencies_by(files, &TestShard.shard_of(&1, shards))
        Enum.map(1..shards//1, &"#{&1}\t#{Map.get(counts, &1, 0)}")

      true ->
        shard = opts[:shard] || Mix.raise("aiur.test_shard: --shard is required unless --map or --counts is given")

        shard in 1..shards//1 ||
          Mix.raise("aiur.test_shard: --shard must be in 1..#{shards}, got: #{shard}")

        selected = TestShard.select(files, shard, shards)

        selected != [] ||
          Mix.raise("aiur.test_shard: shard #{shard}/#{shards} resolved to zero of #{length(files)} test files")

        selected
    end
  end

  defp emit(nil, lines), do: Enum.each(lines, fn line -> Mix.shell().info(line) end)
  defp emit(path, lines), do: File.write!(path, Enum.map(lines, &[&1, ?\n]))
end
