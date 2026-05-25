defmodule Aiur.TestReset do
  @moduledoc """
  Implements the `aiur --test` reset workflow for the 3-ticket events
  sandbox. Four required safety guards:

    1. **Pinned ticket IDs** — every action gated on
       `.aiur-test-tickets.json#tickets`. If empty, abort with a clear
       message directing the operator to populate it.
    2. **Clean git tree** — refuses to run with uncommitted changes;
       `--force` overrides.
    3. **Expected remote** — `git remote get-url origin` must match
       `expected_remote` in the tickets file; `--allow-remote`
       overrides.
    4. **Dry-run by default** — without `--confirm`, prints the plan
       and exits 0.

  ## What it does

  For each pinned ticket:
    - Strips `agent:in-progress` / `agent:done` labels, re-adds `agent:todo`
    - Deletes the local + remote `aiur/<id>` branch (best-effort; 404 OK)
    - Closes any open PR from the `aiur/<id>` branch (best-effort)
    - Removes the per-issue workspace under `Config.workspace_root/0`
    - Deletes the `.subscriptions.json` file for the ticket

  **Always restored**: sandbox baseline (`git checkout HEAD --
  elixir/lib/aiur/sandbox/`) — refuses if HEAD doesn't contain the
  baseline files.

  **Never deleted**: `<logs-root>/<repo>.event_id` (the
  `IdGenerator` counter file). Wiping it would let post-reset events
  re-use IDs from before the reset, breaking the at-least-once cursor
  contract.
  """

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @tickets_file ".aiur-test-tickets.json"

  @baseline_files [
    "elixir/lib/aiur/sandbox/event_flow_demo.ex",
    "elixir/lib/aiur/sandbox/event_flow_unrelated_1.ex",
    "elixir/lib/aiur/sandbox/event_flow_unrelated_2.ex",
    "elixir/lib/aiur/sandbox/event_flow_unrelated_3.ex"
  ]

  @type opts :: %{
          optional(:confirm) => boolean(),
          optional(:force) => boolean(),
          optional(:allow_remote) => boolean(),
          optional(:repo_root) => Path.t()
        }

  @spec run(map() | keyword()) :: :ok | {:error, term()}
  def run(opts \\ %{}) do
    opts = normalize_opts(opts)

    with {:ok, tickets_data} <- read_tickets_file(opts.repo_root),
         {:ok, tickets} <- validate_pinned_tickets(tickets_data),
         :ok <- guard_clean_git(opts),
         :ok <- guard_expected_remote(tickets_data, opts),
         :ok <- guard_baseline_committed(opts.repo_root) do
      maybe_execute(tickets, opts)
    end
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts) |> normalize_opts()

  defp normalize_opts(opts) when is_map(opts) do
    %{
      confirm: Map.get(opts, :confirm, false),
      force: Map.get(opts, :force, false),
      allow_remote: Map.get(opts, :allow_remote, false),
      repo_root: Map.get(opts, :repo_root, File.cwd!())
    }
  end

  defp read_tickets_file(repo_root) do
    path = Path.join(repo_root, @tickets_file)

    case JsonStore.read(path) do
      {:ok, nil} ->
        emit("--test ABORT: #{@tickets_file} not found at #{path}", :error)
        {:error, :tickets_file_missing}

      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:ok, _} ->
        {:error, :tickets_file_invalid_shape}

      {:error, reason} ->
        {:error, {:tickets_file_read_failed, reason}}
    end
  end

  defp validate_pinned_tickets(%{"tickets" => []}) do
    emit(
      "--test ABORT: #{@tickets_file} has no tickets. " <>
        "Populate `tickets: [<id1>, <id2>, <id3>]` after creating the 3 sandbox tickets " <>
        "with `gh issue create ...`. See aiur skill docs for the runbook.",
      :error
    )

    {:error, :no_tickets_pinned}
  end

  defp validate_pinned_tickets(%{"tickets" => tickets}) when is_list(tickets) do
    case Enum.reject(tickets, &valid_ticket_id?/1) do
      [] ->
        {:ok, Enum.map(tickets, &normalize_id/1)}

      invalid ->
        emit("--test ABORT: invalid ticket ids in #{@tickets_file}: #{inspect(invalid)}", :error)
        {:error, {:invalid_ticket_ids, invalid}}
    end
  end

  defp validate_pinned_tickets(_), do: {:error, :tickets_file_missing_tickets_key}

  defp valid_ticket_id?(id) when is_integer(id) and id > 0, do: true
  defp valid_ticket_id?(_), do: false

  defp normalize_id(id) when is_integer(id), do: id

  defp guard_clean_git(%{force: true}), do: :ok

  defp guard_clean_git(opts) do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true, cd: opts.repo_root) do
      {"", 0} ->
        :ok

      {output, 0} ->
        emit(
          "--test ABORT: working tree is not clean.\n" <>
            output <> "\nCommit/stash changes or re-run with --force.",
          :error
        )

        {:error, :dirty_working_tree}

      {output, _} ->
        emit("--test ABORT: git status failed: #{output}", :error)
        {:error, :git_status_failed}
    end
  end

  defp guard_expected_remote(_tickets_data, %{allow_remote: true}), do: :ok

  defp guard_expected_remote(tickets_data, opts) do
    expected = Map.get(tickets_data, "expected_remote")

    case System.cmd("git", ["remote", "get-url", "origin"],
           stderr_to_stdout: true,
           cd: opts.repo_root
         ) do
      {_, exit_code} when exit_code != 0 ->
        {:error, :no_origin_remote}

      {url_raw, 0} ->
        actual = String.trim(url_raw)

        if expected == nil or actual == expected do
          :ok
        else
          emit(
            "--test ABORT: git remote mismatch.\n" <>
              "  expected: #{expected}\n" <>
              "  actual:   #{actual}\n" <>
              "Re-run with --allow-remote if you're sure.",
            :error
          )

          {:error, :remote_mismatch}
        end
    end
  end

  defp guard_baseline_committed(repo_root) do
    missing =
      Enum.filter(@baseline_files, fn rel ->
        case System.cmd("git", ["cat-file", "-e", "HEAD:" <> rel],
               stderr_to_stdout: true,
               cd: repo_root
             ) do
          {_, 0} -> false
          _ -> true
        end
      end)

    case missing do
      [] ->
        :ok

      _ ->
        emit(
          "--test ABORT: sandbox baseline missing from HEAD: #{inspect(missing)}\n" <>
            "Commit U24's baseline files first.",
          :error
        )

        {:error, {:baseline_missing, missing}}
    end
  end

  defp maybe_execute(tickets, %{confirm: false}) do
    emit("--test DRY-RUN. Pass --confirm to execute.\n", :info)
    print_plan(tickets)
    :ok
  end

  defp maybe_execute(tickets, %{confirm: true} = opts) do
    emit("--test executing reset for #{length(tickets)} tickets...\n", :info)
    Enum.each(tickets, &reset_one(&1, opts))
    restore_baseline(opts)
    emit("--test reset complete.", :info)
    :ok
  end

  defp print_plan(tickets) do
    emit("Tickets to reset:", :info)
    Enum.each(tickets, fn id -> emit("  - #{id}", :info) end)

    emit("\nPer-ticket actions:", :info)
    emit("  - Delete subscriptions file for <id>", :info)
    emit("  - Remove workspace at <workspace_root>/<id> (fans across worker.ssh_hosts)", :info)
    emit("  - Delete remote branch aiur/<id>", :info)
    emit("  - Close any open PR from aiur/<id>", :info)
    emit("  - Strip every agent:* label, re-add agent:todo", :info)
    emit("\nAlways:", :info)
    emit("  - Restore sandbox baseline (git checkout HEAD -- " <> Enum.join(@baseline_files, " "), :info)
    emit("  - Preserve <repo>.event_id (IdGenerator counter)", :info)
  end

  defp reset_one(id, _opts) do
    Logger.info("aiur_test_reset starting ticket=#{id}")

    delete_subscriptions_file(id)
    delete_workspace(id)
    delete_remote_branch(id)
    close_open_pr(id)
    reset_labels(id)
    Logger.info("aiur_test_reset finished ticket=#{id}")
  end

  defp delete_subscriptions_file(id) do
    path = subscriptions_path(id)

    case File.rm(path) do
      :ok -> emit("  rm #{path}", :info)
      {:error, :enoent} -> :ok
      {:error, reason} -> emit("  WARN rm #{path} failed: #{inspect(reason)}", :warning)
    end
  end

  # Per-issue workspace clone (typically <workspace_root>/<id>) carries
  # the agent's uncommitted edits, untracked files, and git state from
  # the prior session. Without this, the agent on the next run starts
  # in a dirty tree and reports "I see uncommitted changes" — exactly
  # the symptom the operator hit. Fans out across `worker.ssh_hosts`
  # when configured.
  defp delete_workspace(id) do
    Aiur.Workspace.remove_issue_workspaces(to_string(id))
    emit("  rm workspace for #{id}", :info)
  rescue
    error ->
      emit("  WARN workspace cleanup for #{id} failed: #{Exception.message(error)}", :warning)
  end

  defp delete_remote_branch(id) do
    branch = "aiur/#{id}"

    case System.cmd("git", ["push", "origin", "--delete", branch], stderr_to_stdout: true) do
      {_, 0} -> emit("  deleted origin/#{branch}", :info)
      {output, _} -> emit("  remote branch #{branch}: #{String.trim(output)}", :info)
    end
  end

  defp close_open_pr(id) do
    branch = "aiur/#{id}"

    case System.cmd("gh", ["pr", "close", branch, "--delete-branch=false"], stderr_to_stdout: true) do
      {_, 0} -> emit("  closed PR on #{branch}", :info)
      {_, _} -> :ok
    end
  end

  # Strip every agent:* label and re-add agent:todo so the orchestrator
  # treats the issue as queued on the next dispatch poll. Without this,
  # tickets that the previous run flipped to agent:in-progress (or
  # agent:human-review, agent:done) stay in that state and either
  # never re-enter the dispatch set or skip the queue logic entirely.
  defp reset_labels(id) do
    agent_labels =
      "agent:todo,agent:in-progress,agent:human-review,agent:rework,agent:merging,agent:done,agent:error,agent:cancelled,agent:canceled"

    case System.cmd(
           "gh",
           ["issue", "edit", to_string(id), "--remove-label", agent_labels, "--add-label", "agent:todo"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> emit("  reset labels on ##{id} → agent:todo", :info)
      {output, _} -> emit("  WARN label reset on ##{id}: #{String.trim(output)}", :warning)
    end
  end

  defp restore_baseline(opts) do
    # If the operator passed --force AND any sandbox file has uncommitted
    # local changes, stash them first so destructive checkout doesn't
    # silently lose work.
    if opts.force, do: stash_sandbox_if_dirty(opts)

    args = ["checkout", "HEAD", "--"] ++ @baseline_files

    case System.cmd("git", args, stderr_to_stdout: true, cd: opts.repo_root) do
      {_, 0} -> emit("  restored sandbox baseline from HEAD", :info)
      {output, code} -> emit("  WARN baseline restore exit=#{code}: #{output}", :warning)
    end
  end

  defp stash_sandbox_if_dirty(opts) do
    args = ["status", "--porcelain", "--"] ++ @baseline_files

    case System.cmd("git", args, stderr_to_stdout: true, cd: opts.repo_root) do
      {"", _} ->
        :ok

      {dirty, _} ->
        emit(
          "  WARN --force with uncommitted sandbox edits:\n" <> dirty <>
            "Stashing before checkout.",
          :warning
        )

        stash_msg = "aiur-test-reset auto-stash #{DateTime.utc_now() |> DateTime.to_iso8601()}"

        System.cmd("git", ["stash", "push", "-m", stash_msg, "--"] ++ @baseline_files,
          stderr_to_stdout: true,
          cd: opts.repo_root
        )

        :ok
    end
  end

  defp subscriptions_path(id) do
    Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.#{id}.subscriptions.json")
  end

  defp emit(msg, level) do
    IO.puts(:stderr, msg)

    case level do
      :error -> Logger.error(msg)
      :warning -> Logger.warning(msg)
      _ -> Logger.info(msg)
    end
  end
end
