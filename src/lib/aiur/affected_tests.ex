defmodule Aiur.AffectedTests do
  @moduledoc """
  Deterministic mapping from changed source paths to the ExUnit test files the
  scoped pre-PR gate should run, so an agent does not spend a reasoning pass each
  turn choosing which tests to run. `make ci` remains the authoritative full gate.

  Paths are repo-relative as `git diff --name-only` emits them (e.g.
  `src/lib/aiur/foo.ex`). A changed `src/lib/**/X.ex` maps to its sibling
  `src/test/**/X_test.exs`; a changed `*_test.exs` maps to itself. The caller may
  add direct xref dependents via `:dependent_sources`, and those source paths
  are mapped the same way. Changes that cannot be classified safely — including
  test support, executable/build files, Gettext `.po` files, `mix.exs`/`mix.lock`,
  and runtime config — force the full suite.
  """

  @type path :: String.t()

  @doc """
  Map changed repo-relative paths to `{:scoped, test_files}` or `{:full, reason}`.

  Options:
    * `:exists?` — predicate deciding whether a mapped test file is real
      (defaults to `File.exists?/1` joined under `:base_dir`).
    * `:base_dir` — repo root used by the default `:exists?` (defaults to `"."`).
    * `:dependent_sources` — repo-relative library sources found through xref.
  """
  @spec select([path], keyword()) :: {:scoped, [path]} | {:full, String.t()}
  def select(changed, opts \\ []) do
    base = Keyword.get(opts, :base_dir, ".")
    exists? = Keyword.get(opts, :exists?, fn p -> File.exists?(Path.join(base, p)) end)
    dependent_sources = Keyword.get(opts, :dependent_sources, [])
    changed = Enum.uniq(changed)
    unknown = Enum.reject(changed, &recognized?/1)

    cond do
      changed == [] ->
        {:scoped, []}

      Enum.any?(changed, &forces_full?/1) ->
        {:full, "changed files include test support / gettext / mix / config paths that a scoped run cannot capture"}

      unknown != [] ->
        {:full, "changed files cannot be classified safely: #{Enum.join(unknown, ", ")}"}

      true ->
        scoped_tests(changed, dependent_sources, exists?)
    end
  end

  defp scoped_tests(changed, dependent_sources, exists?) do
    sources = Enum.filter(changed, &library_source?/1)

    tests =
      (changed ++ dependent_sources)
      |> Enum.flat_map(&test_candidates/1)
      |> Enum.uniq()
      |> Enum.filter(exists?)

    cond do
      sources != [] and tests == [] ->
        {:full, "no direct or xref-dependent tests were found for changed library sources"}

      true ->
        {:scoped, tests}
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

  defp recognized?(path) do
    library_source?(path) or
      (String.starts_with?(path, "src/test/") and String.ends_with?(path, "_test.exs")) or
      documentation?(path) or
      forces_full?(path)
  end

  defp documentation?(path) do
    String.starts_with?(path, "docs/") or String.ends_with?(path, ".md")
  end

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
