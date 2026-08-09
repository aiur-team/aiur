defmodule Aiur.Workspace.Checkout do
  @moduledoc "Git branch selection for a freshly materialized workspace: live-origin-tip aiur/<id> vs PR-anchored head ref, plus the shared branch query."

  alias Aiur.{PathSafety, RepoBase, TicketBranch}

  @doc "Returns whether `workspace` is a usable checkout rooted at that exact path."
  @spec valid_workspace?(Path.t()) :: boolean()
  def valid_workspace?(workspace) when is_binary(workspace) do
    with true <- File.dir?(workspace),
         {git_toplevel, 0} <-
           System.cmd("git", ["-C", workspace, "rev-parse", "--show-toplevel"], stderr_to_stdout: true),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_git_toplevel} <- PathSafety.canonicalize(String.trim(git_toplevel)),
         true <- canonical_workspace == canonical_git_toplevel,
         {_head, 0} <- System.cmd("git", ["-C", workspace, "rev-parse", "--verify", "HEAD"], stderr_to_stdout: true),
         {_status, 0} <- System.cmd("git", ["-C", workspace, "status", "--porcelain"], stderr_to_stdout: true) do
      true
    else
      _ -> false
    end
  end

  def valid_workspace?(_workspace), do: false

  @spec checkout_fresh_branch(Path.t()) :: :ok | {:error, term()}
  # Branch the agent's `aiur/<id>` off the LIVE `origin/<base>` tip rather than the
  # warm base's copied HEAD. The warm base only refetches on a timer/dispatch gate
  # (#567), so without this a materialized workspace can silently start from stale
  # configured base branch. Fetch that branch and branch off its origin tip; if
  # there's no usable remote (tests, offline, detached HEAD), fall back to the
  # copied HEAD — today's behavior — so materialize still succeeds.
  def checkout_fresh_branch(workspace),
    do: checkout_fresh_branch(workspace, branch_for(workspace))

  @spec checkout_fresh_branch(Path.t(), String.t()) :: :ok | {:error, term()}
  def checkout_fresh_branch(workspace, branch_name) when is_binary(branch_name) do
    # A re-created workspace may already have a remote ticket branch (for
    # example, after its title changed while an open PR still points at the
    # original suffix). Resume that branch's tip rather than recreating its
    # name from the configured base. New tickets have no such ref and retain
    # the normal live-base checkout below.
    copied_base_head = current_head_sha(workspace)

    case fetch_remote_branch(workspace, branch_name) do
      :ok ->
        with :ok <- checkout_fetched_branch(workspace, branch_name),
             :ok <- record_branch_start(workspace, copied_base_head) do
          :ok
        end

      :no_remote ->
        with :ok <- checkout_branch(workspace, branch_name, fresh_base_start_point(workspace)),
             :ok <- record_branch_start(workspace, "HEAD") do
          :ok
        end
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
    copied_base_head = current_head_sha(workspace)

    case fetch_remote_branch(workspace, pr_head_ref) do
      :ok ->
        with :ok <- checkout_fetched_branch(workspace, pr_head_ref),
             :ok <- record_branch_start(workspace, copied_base_head) do
          :ok
        end

      :no_remote ->
        with :ok <- checkout_local_pr_branch(workspace, pr_head_ref),
             :ok <- record_branch_start(workspace, "HEAD") do
          :ok
        end
    end
  end

  @spec current_branch(Path.t()) :: String.t() | nil
  def current_branch(workspace) do
    case System.cmd("git", ["-C", workspace, "symbolic-ref", "--quiet", "--short", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp fetch_remote_branch(workspace, branch_name) do
    case System.cmd(
           "git",
           ["-C", workspace, "fetch", "origin", branch_name, "--quiet"],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      _ -> :no_remote
    end
  end

  defp checkout_fetched_branch(workspace, branch_name) do
    # `git checkout -B <ref> FETCH_HEAD` points the local branch at the freshly
    # fetched remote tip (a plain `checkout <ref>` could resolve to a stale local
    # ref). `--track origin/<ref>` is intentionally avoided: the remote-tracking
    # ref may not exist yet for a one-shot fetch by ref, and FETCH_HEAD is the
    # tip we just pulled.
    case System.cmd(
           "git",
           ["-C", workspace, "checkout", "-B", branch_name, "FETCH_HEAD"],
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

  defp checkout_branch(workspace, branch_name, start_point) do
    args = ["-C", workspace, "checkout", "-B", branch_name] ++ start_point

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      other -> {:error, other}
    end
  end

  defp record_branch_start(workspace, candidate) do
    with {merge_base, 0} <-
           System.cmd("git", ["-C", workspace, "merge-base", candidate, "HEAD"], stderr_to_stdout: true),
         {_out, 0} <-
           System.cmd(
             "git",
             ["-C", workspace, "update-ref", "refs/aiur/branch-start", String.trim(merge_base)],
             stderr_to_stdout: true
           ) do
      :ok
    else
      other -> {:error, other}
    end
  end

  defp current_head_sha(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--verify", "HEAD"], stderr_to_stdout: true) do
      {head, 0} -> String.trim(head)
      _ -> "HEAD"
    end
  end

  # `["origin/<base>"]` when the configured base branch could be refetched, else `[]`.
  defp fresh_base_start_point(workspace) do
    with base when is_binary(base) <- RepoBase.base_branch(),
         {_out, 0} <-
           System.cmd("git", ["-C", workspace, "fetch", "origin", base, "--quiet"], stderr_to_stdout: true) do
      ["origin/" <> base]
    else
      _ -> []
    end
  end

  defp branch_for(workspace), do: TicketBranch.legacy_branch_name(Path.basename(workspace))
end
