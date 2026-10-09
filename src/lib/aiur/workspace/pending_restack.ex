defmodule Aiur.Workspace.PendingRestack do
  @moduledoc false
  require Logger
  alias Aiur.Stacking.GitCommand

  @spec apply(Path.t()) :: :ok | :skip_hook | {:error, term()}
  def apply(workspace) do
    if File.dir?(Path.join(workspace, ".git")) or File.regular?(Path.join(workspace, ".git")), do: apply_checkout(workspace), else: :ok
  end

  defp apply_checkout(workspace) do
    git = fn args -> GitCommand.run(workspace, args) end
    {branch, _status} = git.(["symbolic-ref", "--quiet", "--short", "HEAD"])
    ref = "refs/aiur/restack/pending/#{String.trim(branch)}"

    case git.(["rev-parse", "--verify", ref]) do
      {sha, 0} -> advance(git, workspace, ref, String.trim(sha))
      _absent -> conflict(git, workspace, String.trim(branch))
    end
  end

  defp advance(git, workspace, ref, sha) do
    case git.(["status", "--porcelain", "--untracked-files=no"]) do
      {"", 0} -> advance_clean(git, workspace, ref, sha)
      {_dirty, 0} -> skip(workspace, :uncommitted_work)
      _failure -> {:error, :pending_restack_status_failed}
    end
  end

  defp advance_clean(git, workspace, ref, sha) do
    case git.(["merge-base", "--is-ancestor", sha, "HEAD"]) do
      {_, 0} -> clear_conflict(git, ref, sha)
      {_, 1} -> forward(git, workspace, ref, sha)
      _failure -> {:error, :pending_restack_ancestry_failed}
    end
  end

  defp forward(git, workspace, ref, sha) do
    case git.(["merge-base", "--is-ancestor", "HEAD", sha]) do
      {_, 0} -> merge(git, workspace, ref, sha)
      {_, 1} -> skip(workspace, :local_commits)
      _failure -> {:error, :pending_restack_ancestry_failed}
    end
  end

  defp merge(git, workspace, ref, sha) do
    case git.(["merge", "--ff-only", sha]) do
      {_, 0} ->
        case git.(["update-ref", "-d", ref, sha]) do
          {_, 0} -> :ok
          _failure -> {:error, :pending_restack_receipt_failed}
        end

      _failure ->
        case git.(["status", "--porcelain", "--untracked-files=no"]) do
          {dirty, 0} when dirty != "" -> skip(workspace, :uncommitted_work)
          _clean_or_failed -> {:error, :pending_restack_merge_failed}
        end
    end
  end

  defp conflict(git, workspace, branch) do
    ref = "refs/aiur/restack/conflict/#{branch}"

    case git.(["rev-parse", "--verify", ref]) do
      {sha, 0} ->
        case git.(["merge-base", "--is-ancestor", String.trim(sha), "HEAD"]) do
          {_, 0} -> clear_conflict(git, ref, String.trim(sha))
          {_, 1} -> skip(workspace, :restack_conflict)
          _failure -> {:error, :restack_conflict_ancestry_failed}
        end

      _absent ->
        :ok
    end
  end

  defp clear_conflict(git, ref, sha) do
    case git.(["update-ref", "-d", ref, sha]) do
      {_, 0} -> :ok
      _failure -> {:error, :restack_conflict_receipt_failed}
    end
  end

  defp skip(workspace, reason) do
    Logger.warning("Pending restack requires agent reconciliation: workspace=#{workspace} reason=#{reason}; preserving local work and skipping before_run")
    :skip_hook
  end
end
