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
         {:ok, changed} <- changed_files(root, base) do
      print_selection(Aiur.AffectedTests.select(changed, base_dir: root))
    else
      {:error, reason} -> Mix.raise("Cannot select affected tests safely: #{reason}")
    end
  end

  defp print_selection({:full, reason}) do
    Mix.shell().info("# full suite recommended: #{reason}")
    Mix.shell().info("make ci")
  end

  defp print_selection({:scoped, _tests, true}) do
    Mix.shell().info("cd src && mise exec -- mix test --max-cases 4 --stale")
  end

  defp print_selection({:scoped, [], false}) do
    Mix.shell().info("# no affected test files detected for the changed source")
  end

  defp print_selection({:scoped, tests, false}) do
    mix_paths =
      Enum.map(tests, fn path ->
        path
        |> String.replace_prefix("src/", "")
        |> shell_quote()
      end)

    Mix.shell().info("cd src && mise exec -- mix test --max-cases 4 " <> Enum.join(mix_paths, " "))
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp changed_files(root, base) do
    with {:ok, committed} <- git(root, ["diff", "--name-only", base, "--"]),
         {:ok, working} <- git(root, ["diff", "--name-only", "--"]),
         {:ok, untracked} <- git(root, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok, Enum.uniq(committed ++ working ++ untracked)}
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
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.split(out, "\n", trim: true)}
      {out, status} -> {:error, "git #{Enum.join(args, " ")} failed (#{status}): #{String.trim(out)}"}
    end
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
