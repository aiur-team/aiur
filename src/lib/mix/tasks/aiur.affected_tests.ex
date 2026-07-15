defmodule Mix.Tasks.Aiur.AffectedTests do
  use Mix.Task

  @shortdoc "Print the scoped `mix test` command for files changed vs the base branch"

  @moduledoc """
  Deterministically maps changed source files to their ExUnit test files so the
  scoped pre-PR gate does not need the agent to reason about which tests to run.

      mix aiur.affected_tests [base_ref]

  Prints a `mix test --max-cases 4 <files>` line, or advises running the full
  `make ci` suite when the change (gettext, mix, or config) cannot be scoped
  safely. `make ci` remains the authoritative gate; this only picks the scoped
  local run. Mapping lives in `Aiur.AffectedTests.select/2`.
  """

  @impl Mix.Task
  def run(args) do
    root = repo_root()
    base = List.first(args) || default_base(root)
    changed = changed_files(root, base)

    case Aiur.AffectedTests.select(changed, base_dir: root) do
      {:full, reason} ->
        Mix.shell().info("# full suite recommended: #{reason}")
        Mix.shell().info("make ci")

      {:scoped, []} ->
        Mix.shell().info("# no affected test files detected for the changed source")

      {:scoped, tests} ->
        mix_paths = Enum.map(tests, &String.replace_prefix(&1, "src/", ""))
        Mix.shell().info("mix test --max-cases 4 " <> Enum.join(mix_paths, " "))
    end
  end

  defp changed_files(root, base) do
    committed = git(root, ["diff", "--name-only", base, "--"])
    working = git(root, ["diff", "--name-only", "--"])
    untracked = git(root, ["ls-files", "--others", "--exclude-standard"])
    Enum.uniq(committed ++ working ++ untracked)
  end

  defp default_base(root) do
    case System.cmd("git", ["merge-base", "HEAD", "origin/main"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {sha, 0} -> String.trim(sha)
      _ -> "HEAD~1"
    end
  end

  defp git(root, args) do
    {out, _status} = System.cmd("git", args, cd: root)
    String.split(out, "\n", trim: true)
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
