defmodule Aiur.AffectedTests do
  @moduledoc """
  Deterministic mapping from changed source paths to the ExUnit test files the
  scoped pre-PR gate should run, so an agent does not spend a reasoning pass each
  turn choosing which tests to run. `make ci` remains the authoritative full gate.

  Paths are repo-relative as `git diff --name-only` emits them (e.g.
  `src/lib/aiur/foo.ex`). A changed `src/lib/**/X.ex` maps to its sibling
  `src/test/**/X_test.exs`; a changed `*_test.exs` maps to itself. Library
  changes also request `mix test --stale`, which includes tests that reference
  changed modules even when they are not sibling-named. Changes that neither
  strategy can safely capture — test support, Gettext `.po` files,
  `mix.exs`/`mix.lock`, and runtime config — force the full suite.
  """

  @type path :: String.t()

  @doc """
  Map changed repo-relative paths to `{:scoped, test_files, stale?}` or
  `{:full, reason}`. `stale?` tells the caller to use `mix test --stale` rather
  than trusting sibling-file mapping alone.

  Options:
    * `:exists?` — predicate deciding whether a mapped test file is real
      (defaults to `File.exists?/1` joined under `:base_dir`).
    * `:base_dir` — repo root used by the default `:exists?` (defaults to `"."`).
  """
  @spec select([path], keyword()) :: {:scoped, [path], boolean()} | {:full, String.t()}
  def select(changed, opts \\ []) do
    base = Keyword.get(opts, :base_dir, ".")
    exists? = Keyword.get(opts, :exists?, fn p -> File.exists?(Path.join(base, p)) end)
    changed = Enum.uniq(changed)

    cond do
      changed == [] ->
        {:scoped, [], false}

      Enum.any?(changed, &forces_full?/1) ->
        {:full, "changed files include test support / gettext / mix / config paths that a scoped run cannot capture"}

      true ->
        tests =
          changed
          |> Enum.flat_map(&test_candidates/1)
          |> Enum.uniq()
          |> Enum.filter(exists?)

        {:scoped, tests, Enum.any?(changed, &library_source?/1)}
    end
  end

  @spec test_candidates(path) :: [path]
  defp test_candidates("src/test/" <> _ = path) do
    if String.ends_with?(path, "_test.exs"), do: [path], else: []
  end

  defp test_candidates("src/lib/" <> rest) do
    if String.ends_with?(rest, ".ex") do
      ["src/test/" <> String.trim_trailing(rest, ".ex") <> "_test.exs"]
    else
      []
    end
  end

  defp test_candidates(_path), do: []

  @spec library_source?(path) :: boolean()
  defp library_source?("src/lib/" <> rest), do: String.ends_with?(rest, ".ex")
  defp library_source?(_path), do: false

  @spec forces_full?(path) :: boolean()
  defp forces_full?(path) do
    String.ends_with?(path, ".po") or
      String.ends_with?(path, ".pot") or
      String.ends_with?(path, "mix.exs") or
      String.ends_with?(path, "mix.lock") or
      String.starts_with?(path, "src/config/") or
      String.starts_with?(path, "config/") or
      (String.starts_with?(path, "src/test/") and not String.ends_with?(path, "_test.exs"))
  end
end
