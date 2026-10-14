defmodule Mix.Tasks.Aiur.AffectedTests do
  use Mix.Task

  alias Aiur.AffectedTests.Command
  alias Aiur.AffectedTests.GitDiff

  @shortdoc "Print the scoped `mix test` command for files changed vs the base branch"

  @moduledoc """
  Deterministically maps changed source files to their ExUnit test files so the
  scoped pre-PR gate does not need the agent to reason about which tests to run.
  It also scans the full test tree for function, option-key, atom, and string
  references deleted from individual source diff hunks, so root-level sibling
  tests are not hidden by topic-directory selections.

      mix aiur.affected_tests [base_ref] [--json]

  Prints a root-runnable `cd src && mise exec -- mix test ...` line, or advises
  running the full `make ci` suite when the change cannot be scoped safely.
  `make ci` remains the authoritative gate; this only picks the scoped local
  run. Mapping lives in `Aiur.AffectedTests.select/2`.

  ## Base branch resolution

  When no `base_ref` argument is supplied, the base is resolved in order:

  1. `AIUR_BASE_BRANCH` environment variable (set in agent processes)
  2. `tracker.base_branch` from the `.aiur/config` file (`Aiur.Config.base_branch/0`)

  The resolved name is prefixed with `origin/` and used as the merge-base ref.
  """

  @impl Mix.Task
  def run(args) do
    root = repo_root()
    json? = "--json" in args
    args = Enum.reject(args, &(&1 == "--json"))

    with {:ok, base} <- requested_or_default_base(root, args),
         {:ok, lines} <- selection(root, base, json?) do
      Enum.each(lines, &print_line/1)
    else
      {:error, reason} -> Mix.raise("Cannot select affected tests safely: #{reason}")
    end
  end

  @doc false
  @spec selection(String.t(), String.t(), boolean()) :: {:ok, [String.t()]} | {:error, String.t()}
  def selection(root, base, json? \\ false) do
    with {:ok, diff_range} <- GitDiff.range(root, base),
         {:ok, changed} <- changed_files(root, base),
         {:ok, dependents} <- xref_dependents(root, changed),
         {:ok, references} <- deleted_reference_tests(root, diff_range) do
      selected =
        Aiur.AffectedTests.select(changed,
          base_dir: root,
          dependent_sources: dependents,
          reference_tests: references
        )

      {:ok, output_lines(selected, json?, changed)}
    end
  end

  @spec selection_json({:full, String.t()} | {:scoped, [String.t()]}) :: String.t()
  def selection_json({:full, reason}), do: Jason.encode!(%{status: "full", reason: reason})
  def selection_json({:scoped, tests}), do: Jason.encode!(%{status: "scoped", tests: tests})

  @spec command({:full, String.t()} | {:full, String.t(), [String.t()]} | {:scoped, [String.t()]}) :: [String.t()]
  def command({:full, reason, changed}),
    do: command({:full, "#{reason}; changed paths: #{Enum.join(changed, ", ")}"})

  def command({:full, reason}),
    do: Command.build({:full, reason})

  def command(selection), do: Command.build(selection)

  defp output_lines(selection, true, _changed), do: [selection_json(selection)]
  defp output_lines({:full, reason}, false, changed), do: command({:full, reason, changed})
  defp output_lines(selection, false, _changed), do: command(selection)

  defp print_line(line), do: Mix.shell().info(line)

  @doc false
  @spec changed_files(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def changed_files(root, base) do
    case System.get_env("AIUR_CI_CHANGED_PATHS_B64") do
      nil ->
        with {:ok, diff_range} <- GitDiff.range(root, base) do
          changed_files_for_range(root, diff_range)
        end

      encoded ->
        with {:ok, json} <- Base.decode64(encoded),
             {:ok, paths} <- Jason.decode(json),
             true <- is_list(paths) and Enum.all?(paths, &is_binary/1) do
          {:ok, Enum.uniq(paths)}
        else
          _ -> {:error, "AIUR_CI_CHANGED_PATHS_B64 must encode a JSON array of paths"}
        end
    end
  end

  defp changed_files_for_range(root, {base, head}) do
    with {:ok, committed} <- GitDiff.changed_paths(root, base, head),
         {:ok, working} <- git(root, ["diff", "--name-only", "--"]),
         {:ok, untracked} <- git(root, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok, Enum.uniq(committed ++ working ++ untracked)}
    end
  end

  @doc false
  @spec deleted_reference_tests(String.t(), String.t() | {String.t(), String.t()}) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def deleted_reference_tests(root, base) when is_binary(base) do
    case GitDiff.diff(root, ["diff", "--unified=0", base, "--", "src/lib"]) do
      {:ok, lines} -> deleted_reference_matches(root, lines)
      error -> error
    end
  end

  def deleted_reference_tests(root, {base, head}), do: deleted_reference_diff(root, base, head)

  defp deleted_reference_diff(root, base, head) do
    case GitDiff.diff(root, ["diff", "--unified=0", base, head, "--", "src/lib"]) do
      {:ok, lines} ->
        deleted_reference_matches(root, lines)

      error ->
        error
    end
  end

  defp deleted_reference_matches(root, lines) do
    tests =
      lines
      |> Enum.join("\n")
      |> Aiur.AffectedTests.deleted_reference_terms()
      |> then(&Aiur.AffectedTests.reference_test_files(root, &1))

    {:ok, tests}
  end

  @doc false
  @spec xref_sinks([String.t()], String.t()) :: [String.t()]
  def xref_sinks(changed, root) do
    changed
    |> Enum.filter(fn path ->
      String.starts_with?(path, "src/lib/") and String.ends_with?(path, ".ex") and
        File.exists?(Path.join(root, path))
    end)
    |> Enum.map(&String.replace_prefix(&1, "src/", ""))
  end

  defp xref_dependents(root, changed) do
    sinks = xref_sinks(changed, root)

    if sinks == [] do
      {:ok, []}
    else
      ["compile", "export", "runtime"]
      |> Enum.reduce_while({:ok, []}, &reduce_xref_label(&1, &2, root, sinks))
      |> case do
        {:ok, sources} -> {:ok, Enum.uniq(sources)}
        error -> error
      end
    end
  end

  defp reduce_xref_label(label, {:ok, acc}, root, sinks) do
    case xref_sources_for_label(root, sinks, label) do
      {:ok, sources} -> {:cont, {:ok, sources ++ acc}}
      {:error, reason} -> {:halt, {:error, "xref dependency expansion failed: #{reason}"}}
    end
  end

  defp xref_sources_for_label(root, sinks, label) do
    args =
      ["xref", "graph", "--only-nodes", "--only-direct", "--label", label] ++
        Enum.flat_map(sinks, &["--sink", &1])

    case git_like_command(Path.join(root, "src"), "mix", args) do
      {:ok, lines} ->
        sources =
          lines
          |> Enum.filter(&String.starts_with?(&1, "lib/"))
          |> Enum.map(&("src/" <> &1))

        {:ok, sources}

      error ->
        error
    end
  end

  defp requested_or_default_base(_root, [base | _]), do: {:ok, base}

  defp requested_or_default_base(root, []) do
    origin = default_origin()

    case git(root, ["merge-base", "HEAD", origin]) do
      {:ok, [sha]} -> {:ok, sha}
      {:ok, other} -> {:error, "git merge-base returned #{inspect(other)}"}
      {:error, reason} -> {:error, "#{reason}\nHint: base ref `#{origin}` not found locally; run `git fetch origin`"}
    end
  end

  @doc false
  @spec default_origin((-> String.t())) :: String.t()
  def default_origin(config_fn \\ &Aiur.Config.base_branch/0) do
    case System.get_env("AIUR_BASE_BRANCH") do
      branch when is_binary(branch) and branch != "" ->
        "origin/" <> String.trim_leading(branch, "origin/")

      _ ->
        "origin/" <> config_fn.()
    end
  end

  defp git(root, args) do
    git_like_command(root, "git", args)
  end

  defp git_like_command(root, executable, args) do
    case System.cmd(executable, args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.split(out, "\n", trim: true)}
      {out, status} -> {:error, "#{executable} #{Enum.join(args, " ")} failed (#{status}): #{String.trim(out)}"}
    end
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
