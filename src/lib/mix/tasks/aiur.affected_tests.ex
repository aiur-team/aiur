defmodule Mix.Tasks.Aiur.AffectedTests do
  use Mix.Task

  @shortdoc "Print the scoped `mix test` command for files changed vs the base branch"

  @moduledoc """
  Deterministically maps changed source files to their ExUnit test files so the
  scoped pre-PR gate does not need the agent to reason about which tests to run.

      mix aiur.affected_tests [base_ref]

  Prints a root-runnable `cd src && mise exec -- mix test ...` line, or advises
  running the full `make ci` suite when the change cannot be scoped safely.
  `make ci` remains the authoritative gate; this only picks the scoped local
  run. Mapping lives in `Aiur.AffectedTests.select/2`.
  """

  @impl Mix.Task
  def run(args) do
    root = repo_root()

    with {:ok, base} <- requested_or_default_base(root, args),
         {:ok, changed} <- changed_files(root, base),
         {:ok, dependents} <- xref_dependents(root, changed) do
      changed
      |> Aiur.AffectedTests.select(base_dir: root, dependent_sources: dependents)
      |> command()
      |> Enum.each(fn line -> Mix.shell().info(line) end)
    else
      {:error, reason} -> Mix.raise("Cannot select affected tests safely: #{reason}")
    end
  end

  @doc false
  @spec command({:full, String.t()} | {:scoped, [String.t()]}) :: [String.t()]
  def command({:full, reason}),
    do: ["# full suite recommended: #{reason}", "cd src && mise exec -- make ci"]

  def command({:scoped, []}), do: ["# no affected test files detected for the documentation-only change"]

  def command({:scoped, tests}) do
    mix_paths =
      Enum.map(tests, fn path ->
        path
        |> String.replace_prefix("src/", "")
        |> shell_quote()
      end)

    ["cd src && mise exec -- mix test --max-cases 4 " <> Enum.join(mix_paths, " ")]
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp changed_files(root, base) do
    with {:ok, committed} <- git(root, ["diff", "--name-only", base, "--"]),
         {:ok, working} <- git(root, ["diff", "--name-only", "--"]),
         {:ok, untracked} <- git(root, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok, Enum.uniq(committed ++ working ++ untracked)}
    end
  end

  defp xref_dependents(root, changed) do
    sinks =
      changed
      |> Enum.filter(fn path ->
        String.starts_with?(path, "src/lib/") and String.ends_with?(path, ".ex")
      end)
      |> Enum.map(&String.replace_prefix(&1, "src/", ""))

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
    case git(root, ["merge-base", "HEAD", "origin/main"]) do
      {:ok, [sha]} -> {:ok, sha}
      {:ok, other} -> {:error, "git merge-base returned #{inspect(other)}"}
      {:error, reason} -> {:error, reason}
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
