defmodule Aiur.TestReset.Cleanup do
  @moduledoc false

  alias Aiur.Config.Paths
  alias Aiur.Events.SubscriptionStore
  alias Aiur.GitHub.HostCommand
  alias Aiur.{TestReset, TicketBranch}
  alias Aiur.Workspace.Layout

  # The agent records its plan/handoff state as a comment on the issue
  # whose body starts with `## Agent Workpad`. `aiur --test` previously
  # left these alone, so each fresh sandbox run started with the
  # previous run's workpad sitting in the issue — agents would dutifully
  # reconcile against it instead of treating the ticket as a clean slate.
  @doc false
  @spec delete_workpad_comments(integer() | String.t()) :: :ok
  def delete_workpad_comments(id) do
    case HostCommand.run(
           ["api", "repos/{owner}/{repo}/issues/#{id}/comments", "--paginate"],
           stderr_to_stdout: true,
           bot_token: true
         ) do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, comments} when is_list(comments) ->
            delete_each_workpad(id, Enum.filter(comments, &workpad_comment?/1))

          _ ->
            TestReset.warn("##{id} workpad scan: could not parse `gh api` JSON")
        end

      {output, _} ->
        TestReset.warn("##{id} workpad scan failed: #{String.trim(output)}")
    end
  end

  defp delete_each_workpad(id, []) do
    TestReset.ok("##{id} workpad clear (no comments to remove)")
  end

  defp delete_each_workpad(id, comments) do
    failures =
      Enum.reduce(comments, 0, fn comment, acc ->
        case HostCommand.run(
               [
                 "api",
                 "-X",
                 "DELETE",
                 "repos/{owner}/{repo}/issues/comments/#{Map.get(comment, "id")}"
               ],
               stderr_to_stdout: true,
               bot_token: true
             ) do
          {_, 0} -> acc
          {_, _} -> acc + 1
        end
      end)

    count = length(comments)

    if failures == 0 do
      TestReset.ok("##{id} workpad comments removed (#{count})")
    else
      TestReset.warn("##{id} workpad comments: #{count - failures}/#{count} removed; #{failures} failed")
    end
  end

  @doc false
  @spec workpad_comment?(map()) :: boolean()
  def workpad_comment?(%{"body" => body}) when is_binary(body) do
    String.starts_with?(String.trim_leading(body), "## Agent Workpad")
  end

  def workpad_comment?(_), do: false

  @doc false
  @spec delete_subscriptions_file(integer() | String.t()) :: :ok
  def delete_subscriptions_file(id) do
    path = subscriptions_path(id)

    case File.rm(path) do
      :ok -> TestReset.ok("##{id} subscriptions cleared")
      {:error, :enoent} -> :ok
      {:error, reason} -> TestReset.warn("##{id} subscriptions clear failed: #{inspect(reason)}")
    end
  end

  # Per-issue workspace clone (typically <workspace_root>/<repo>/<id>) carries
  # the agent's uncommitted edits, untracked files, and git state from
  # the prior session. Without this, the agent on the next run starts
  # in a dirty tree and reports "I see uncommitted changes" — exactly
  # the symptom the Executor hit. Fans out across `worker.ssh_hosts`
  # when configured.
  #
  # We don't go through `Aiur.Workspace.remove_issue_workspaces/1`
  # because that calls `Aiur.Config.settings!()` which requires
  # .aiur/config to be present and parseable — the reset task runs
  # outside any orchestrator boot, so it may not have a workflow
  # context. Instead we compute the workspace root from
  # `Aiur.Config.workspace_root/0` if available; if not, fall back
  # to the same default `Aiur.Config.Schema.Workspace` uses
  # (`<tmp_dir>/aiur_workspaces`).
  @doc false
  @spec delete_workspace(integer() | String.t()) :: :ok
  def delete_workspace(id) do
    root = workspace_root_with_fallback()
    remove_workspace(id, root)
  end

  @doc false
  @spec remove_workspace(integer() | String.t(), Path.t()) :: :ok
  def remove_workspace(id, root) do
    safe_id = Paths.sanitize(to_string(id))
    path = workspace_path_with_fallback(root, safe_id)

    case File.rm_rf(path) do
      {:ok, []} ->
        TestReset.ok("##{id} workspace already clean")

      {:ok, _} ->
        TestReset.ok("##{id} workspace removed")

      {:error, reason, file} ->
        TestReset.warn("##{id} workspace cleanup failed at #{file}: #{inspect(reason)}")
    end
  end

  defp workspace_path_with_fallback(root, safe_id) do
    Layout.issue_workspace_path(root, safe_id)
  rescue
    _ -> Path.join(root, safe_id)
  catch
    _, _ -> Path.join(root, safe_id)
  end

  defp workspace_root_with_fallback do
    # Config.workspace_root/0 returns the raw YAML value — when the
    # Executor wrote `~/code/aiur-workspaces`, that's what we get.
    # Path.expand/1 resolves `~` against $HOME so the rm path actually
    # points at the real directory. Without this, the rm targets the
    # literal `~/code/aiur-workspaces` (a directory with a tilde in
    # its name, which obviously doesn't exist) and the reset silently
    # leaves the agent's stale workspace in place.
    Aiur.Config.workspace_root() |> Path.expand()
  rescue
    _ -> Path.join(System.tmp_dir!(), "aiur_workspaces")
  catch
    _, _ -> Path.join(System.tmp_dir!(), "aiur_workspaces")
  end

  @doc false
  @spec delete_remote_branch(integer() | String.t()) :: :ok
  def delete_remote_branch(id) do
    # A ticket can have either a legacy branch or a readable suffix. The
    # centralized ticket-branch parser filters the broad remote-ref probe so
    # similarly numbered tickets are never touched.
    branches = list_remote_branches_for(id)

    if branches == [] do
      TestReset.ok("##{id} remote branch already gone")
    else
      Enum.each(branches, &delete_one_remote_branch(id, &1))
    end
  end

  defp list_remote_branches_for(id) do
    pattern = "refs/heads/#{TicketBranch.legacy_branch_name(id)}*"

    case System.cmd("git", ["ls-remote", "--heads", "origin", pattern], stderr_to_stdout: true) do
      {output, 0} -> parse_remote_branches(id, output)
      _ -> []
    end
  end

  defp parse_remote_branches(id, output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&extract_branch_from_ls_remote_line(id, &1))
  end

  defp extract_branch_from_ls_remote_line(id, line) do
    case String.split(line, "refs/heads/", parts: 2) do
      [_, branch] -> filter_id_match(id, String.trim(branch))
      _ -> []
    end
  end

  defp filter_id_match(id, branch) do
    if TicketBranch.ticket_branch?(branch, id), do: [branch], else: []
  end

  defp delete_one_remote_branch(id, branch) do
    case System.cmd("git", ["push", "origin", "--delete", branch], stderr_to_stdout: true) do
      {_, 0} ->
        TestReset.ok("##{id} remote branch #{branch} deleted")

      {output, _} ->
        if String.contains?(output, "remote ref does not exist") do
          :ok
        else
          TestReset.warn("##{id} remote branch #{branch}: #{String.trim(output)}")
        end
    end
  end

  @doc false
  @spec close_open_pr(integer() | String.t()) :: :ok
  def close_open_pr(id) do
    # `gh pr close <branch>` resolves an actual readable or legacy branch to
    # its open PR head; safe to call when no PR exists (silent no-op).
    case list_remote_branches_for(id) do
      [] -> close_pr_for_branch(id, TicketBranch.legacy_branch_name(id))
      branches -> Enum.each(branches, &close_pr_for_branch(id, &1))
    end
  end

  defp close_pr_for_branch(id, branch) do
    case HostCommand.run(["pr", "close", branch, "--delete-branch=false"], stderr_to_stdout: true, bot_token: true) do
      {_, 0} -> TestReset.ok("##{id} PR on #{branch} closed")
      {_, _} -> :ok
    end
  end

  @doc false
  @spec restore_baseline(map(), [String.t()]) :: :ok
  def restore_baseline(opts, baseline_files) do
    # If the Executor passed --force AND any sandbox file has uncommitted
    # local changes, stash them first so destructive checkout doesn't
    # silently lose work.
    if opts.force, do: stash_sandbox_if_dirty(opts, baseline_files)

    args = ["checkout", "HEAD", "--"] ++ baseline_files

    case System.cmd("git", args, stderr_to_stdout: true, cd: opts.repo_root) do
      {_, 0} -> TestReset.ok("sandbox baseline restored")
      {output, code} -> TestReset.warn("baseline restore exit=#{code}: #{output}")
    end
  end

  defp stash_sandbox_if_dirty(opts, baseline_files) do
    args = ["status", "--porcelain", "--"] ++ baseline_files

    case System.cmd("git", args, stderr_to_stdout: true, cd: opts.repo_root) do
      {"", _} ->
        :ok

      {dirty, _} ->
        TestReset.warn(
          "--force with uncommitted sandbox edits:\n" <>
            dirty <>
            "Stashing before checkout."
        )

        stash_msg = "aiur-test-reset auto-stash #{DateTime.utc_now() |> DateTime.to_iso8601()}"

        System.cmd("git", ["stash", "push", "-m", stash_msg, "--"] ++ baseline_files,
          stderr_to_stdout: true,
          cd: opts.repo_root
        )

        :ok
    end
  end

  defp subscriptions_path(id), do: SubscriptionStore.path_for(to_string(id))
end
