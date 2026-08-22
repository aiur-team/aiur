defmodule Aiur.AffectedTests do
  @moduledoc """
  Deterministic mapping from changed source paths to the ExUnit test files the
  scoped pre-PR gate should run, so an agent does not spend a reasoning pass each
  turn choosing which tests to run. `make ci` remains the authoritative full gate.

  Paths are repo-relative as `git diff --name-only` emits them (e.g.
  `src/lib/aiur/foo.ex`). A changed `src/lib/**/X.ex` maps to its sibling
  `src/test/**/X_test.exs`; a changed `*_test.exs` maps to itself. The caller may
  add direct xref dependents via `:dependent_sources`, and those source paths
  are mapped the same way. Deleted function, option-key, atom, and string
  references can add every test file that still contains one, regardless of its
  directory depth. Changes that cannot be classified safely — including test
  support, executable/build files, Gettext `.po` files, `mix.exs`/`mix.lock`, and
  runtime config — force the full suite.
  """

  @type path :: String.t()
  @common_literal_terms MapSet.new(~w(error is_binary ok open per_page state))

  @doc """
  Map changed repo-relative paths to `{:scoped, test_files}` or `{:full, reason}`.

  Options:
    * `:exists?` — predicate deciding whether a mapped test file is real
      (defaults to `File.exists?/1` joined under `:base_dir`).
    * `:base_dir` — repo root used by the default `:exists?` (defaults to `"."`).
    * `:dependent_sources` — repo-relative library sources found through xref.
    * `:reference_tests` — test files containing references deleted by the diff.
  """
  @spec select([path], keyword()) :: {:scoped, [path]} | {:full, String.t()}
  def select(changed, opts \\ []) do
    base = Keyword.get(opts, :base_dir, ".")
    exists? = Keyword.get(opts, :exists?, fn p -> File.exists?(Path.join(base, p)) end)
    dependent_sources = Keyword.get(opts, :dependent_sources, [])
    reference_tests = Keyword.get(opts, :reference_tests, [])
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
        scoped_tests(changed, dependent_sources, reference_tests, exists?)
    end
  end

  defp scoped_tests(changed, dependent_sources, reference_tests, exists?) do
    sources = Enum.filter(changed, &library_source?/1)

    tests =
      (changed ++ dependent_sources ++ reference_tests)
      |> Enum.flat_map(&test_candidates/1)
      |> Enum.uniq()
      |> Enum.filter(exists?)

    if sources != [] and tests == [] do
      {:full, "no direct or xref-dependent tests were found for changed library sources"}
    else
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

  @doc false
  @spec deleted_reference_terms(String.t()) :: [String.t()]
  def deleted_reference_terms(diff) do
    ~r/^@@[^\n]*\n(.*?)(?=^@@|\z)/ms
    |> Regex.scan(diff, capture: :all_but_first)
    |> List.flatten()
    |> Enum.flat_map(&deleted_hunk_terms/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec reference_test_files(String.t(), [String.t()]) :: [path]
  def reference_test_files(_root, []), do: []

  def reference_test_files(root, terms) do
    patterns = Enum.map(terms, &term_pattern/1)

    root
    |> Path.join("src/test/**/*_test.exs")
    |> Path.wildcard()
    |> Enum.filter(&contains_any?(&1, patterns))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  defp deleted_hunk_terms(hunk) do
    removed = prefixed_lines(hunk, "-") |> reference_terms()
    added = prefixed_lines(hunk, "+") |> reference_terms()

    removed
    |> MapSet.difference(added)
    |> MapSet.to_list()
  end

  defp prefixed_lines(hunk, prefix) do
    hunk
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map_join("\n", &String.replace_prefix(&1, prefix, ""))
  end

  defp reference_terms(text) do
    structural_terms =
      [
        captures(text, ~r/:([a-z][a-z0-9_]*[!?]?)/),
        captures(text, ~r/\b([a-z][a-z0-9_]*[!?]?)\s*(?:\(|:)/),
        captures(text, ~r/\bdef(?:delegate|guardp?|macrop?|p)?\s+([a-z][a-z0-9_]*[!?]?)/)
      ]
      |> List.flatten()

    literal_terms =
      text
      |> captures(~r/"([^"\n]{4,})"/)
      |> Enum.reject(&noisy_literal?/1)

    MapSet.new(structural_terms ++ literal_terms)
  end

  defp captures(text, regex), do: Regex.scan(regex, text, capture: :all_but_first) |> List.flatten()

  defp contains_any?(path, patterns) do
    case File.read(path) do
      {:ok, contents} -> Enum.any?(patterns, &Regex.match?(&1, contents))
      {:error, _reason} -> false
    end
  end

  defp noisy_literal?(term),
    do: Regex.match?(~r/^\d+$/, term) or MapSet.member?(@common_literal_terms, term)

  defp term_pattern(term),
    do: Regex.compile!("(?<![A-Za-z0-9_])#{Regex.escape(term)}(?![A-Za-z0-9_])")

  @spec library_source?(path) :: boolean()
  defp library_source?("src/lib/" <> rest), do: String.ends_with?(rest, ".ex")
  defp library_source?(_path), do: false

  defp recognized?(path) do
    library_source?(path) or
      (String.starts_with?(path, "src/test/") and String.ends_with?(path, "_test.exs")) or
      ignorable?(path) or
      forces_full?(path)
  end

  defp ignorable?(path) do
    String.starts_with?(path, "docs/") or
      String.ends_with?(path, ".md") or
      String.starts_with?(path, ".aiur/")
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
