defmodule Aiur.AffectedTests.GitDiff do
  @moduledoc false

  @spec range(String.t(), String.t()) :: {:ok, {String.t(), String.t()}} | {:error, String.t()}
  def range(root, base) do
    if System.get_env("GITHUB_EVENT_NAME") == "pull_request" do
      first_parent_range(root)
    else
      merge_base_range(root, base)
    end
  end

  defp first_parent_range(root) do
    case git(root, ["rev-parse", "HEAD^1"]) do
      {:ok, [first_parent]} -> {:ok, {first_parent, "HEAD"}}
      {:ok, other} -> {:error, "git rev-parse HEAD^1 returned #{inspect(other)}"}
      error -> error
    end
  end

  defp merge_base_range(root, base) do
    case git(root, ["merge-base", "HEAD", base]) do
      {:ok, [sha]} -> {:ok, {sha, "HEAD"}}
      {:ok, other} -> {:error, "git merge-base returned #{inspect(other)}"}
      error -> error
    end
  end

  @spec changed_paths(String.t(), String.t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def changed_paths(root, base, head) do
    case git(root, ["diff", "--name-only", base, head, "--"]) do
      {:ok, paths} -> {:ok, paths}
      error -> error
    end
  end

  @spec diff(String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def diff(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.split(out, "\n", trim: true)}
      {out, status} -> {:error, "git #{Enum.join(args, " ")} failed (#{status}): #{String.trim(out)}"}
    end
  end

  defp git(root, args), do: diff(root, args)
end
