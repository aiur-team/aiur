defmodule Aiur.Workspace.Checkout do
  @moduledoc "Git branch selection for a freshly materialized workspace: live-origin-tip aiur/<id> vs PR-anchored head ref, plus the shared branch query."

  @spec checkout_fresh_branch(Path.t()) :: :ok | {:error, term()}
  # Branch the agent's `aiur/<id>` off the LIVE `origin/<base>` tip rather than the
  # warm base's copied HEAD. The warm base only refetches on a timer/dispatch gate
  # (#567), so without this a materialized workspace can silently start from stale
  # main. Fetch the base's own tracking branch and branch off its origin tip; if
  # there's no usable remote (tests, offline, detached HEAD), fall back to the
  # copied HEAD — today's behavior — so materialize still succeeds.
  def checkout_fresh_branch(workspace) do
    args =
      ["-C", workspace, "checkout", "-B", branch_for(workspace)] ++ fresh_base_start_point(workspace)

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      other -> {:error, other}
    end
  end

  @spec checkout_existing_pr_branch(Path.t(), String.t()) :: :ok | {:error, term()}
  # PR-anchored checkout: fetch the PR's existing head branch from origin and
  # check it out tracking the remote, instead of creating `aiur/<id>`. The agent
  # then works the human's branch directly and pushes back there. If the remote
  # fetch fails (offline/tests with no usable remote), fall back to a local
  # branch off the copied HEAD so materialize still succeeds — the before_run
  # hook / agent will reconcile against origin at push time.
  def checkout_existing_pr_branch(workspace, pr_head_ref) do
    case fetch_pr_head_branch(workspace, pr_head_ref) do
      :ok ->
        checkout_tracking_pr_branch(workspace, pr_head_ref)

      :no_remote ->
        checkout_local_pr_branch(workspace, pr_head_ref)
    end
  end

  @spec current_branch(Path.t()) :: String.t() | nil
  def current_branch(workspace) do
    case System.cmd("git", ["-C", workspace, "symbolic-ref", "--quiet", "--short", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp fetch_pr_head_branch(workspace, pr_head_ref) do
    case System.cmd(
           "git",
           ["-C", workspace, "fetch", "origin", pr_head_ref, "--quiet"],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      _ -> :no_remote
    end
  end

  defp checkout_tracking_pr_branch(workspace, pr_head_ref) do
    # `git checkout -B <ref> FETCH_HEAD` points the local branch at the freshly
    # fetched remote tip (a plain `checkout <ref>` could resolve to a stale local
    # ref). `--track origin/<ref>` is intentionally avoided: the remote-tracking
    # ref may not exist yet for a one-shot fetch by ref, and FETCH_HEAD is the
    # tip we just pulled.
    case System.cmd(
           "git",
           ["-C", workspace, "checkout", "-B", pr_head_ref, "FETCH_HEAD"],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      other -> {:error, other}
    end
  end

  defp checkout_local_pr_branch(workspace, pr_head_ref) do
    case System.cmd(
           "git",
           ["-C", workspace, "checkout", "-B", pr_head_ref],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      other -> {:error, other}
    end
  end

  # `["origin/<base>"]` when the base's tracking branch could be refetched, else `[]`.
  defp fresh_base_start_point(workspace) do
    with base when is_binary(base) <- current_branch(workspace),
         {_out, 0} <-
           System.cmd("git", ["-C", workspace, "fetch", "origin", base, "--quiet"], stderr_to_stdout: true) do
      ["origin/" <> base]
    else
      _ -> []
    end
  end

  defp branch_for(workspace), do: "aiur/" <> Path.basename(workspace)
end
