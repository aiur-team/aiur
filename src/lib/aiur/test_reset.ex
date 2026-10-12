defmodule Aiur.TestReset do
  @moduledoc """
  Implements the `aiur --test` reset workflow for the 3-ticket events
  sandbox. Four required safety guards:

    1. **Pinned ticket IDs** — every action gated on
       `.aiur-test-tickets.json#tickets`. If empty, abort with a clear
       message directing the Executor to populate it.
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
  src/lib/aiur/sandbox/`) — refuses if HEAD doesn't contain the
  baseline files.

  **Never deleted**: `<runtime-state>/event-id.json` (the
  `IdGenerator` counter file). Wiping it would let post-reset events
  re-use IDs from before the reset, breaking the at-least-once cursor
  contract.
  """

  require Logger

  alias Aiur.GitHub.HostCommand
  alias Aiur.JsonStore
  alias Aiur.TestReset.{Cleanup, Tickets}

  @tickets_file ".aiur-test-tickets.json"

  @baseline_files [
    "src/lib/aiur/sandbox/event_flow_demo.ex",
    "src/lib/aiur/sandbox/event_flow_unrelated_1.ex",
    "src/lib/aiur/sandbox/event_flow_unrelated_2.ex",
    "src/lib/aiur/sandbox/event_flow_unrelated_3.ex"
  ]

  @type opts :: %{
          optional(:confirm) => boolean(),
          optional(:force) => boolean(),
          optional(:allow_remote) => boolean(),
          optional(:single) => boolean(),
          optional(:repo_root) => Path.t()
        }

  @type gh_runner :: ([String.t()] -> {String.t(), non_neg_integer()})

  @spec run(map() | keyword()) :: :ok | {:error, term()}
  def run(opts \\ %{}) do
    opts = normalize_opts(opts)

    with :ok <- guard_not_running_in_agent_workspace(opts),
         {:ok, tickets_data} <- read_tickets_file(opts.repo_root) do
      dispatch_reset(tickets_data, opts)
    end
  end

  # Refuse direct reset calls from inside an agent workspace unless the current
  # process came through `scripts/aiurdev`'s agent-IR sandbox path. The shim sets
  # AIUR_AGENT_IR_SANDBOX only after redirecting state, logs, runtime pidfiles,
  # and ports away from the Executor instance. Keeping this guard here protects
  # older workspace checkouts and manual `mix aiur.test.reset` calls.
  defp guard_not_running_in_agent_workspace(opts) do
    cond do
      System.get_env("AIUR_AGENT_IR_SANDBOX") == "1" ->
        :ok

      (marker = System.get_env("AIUR_AGENT_WORKSPACE")) && marker != "" ->
        say("❌ refusing to run mix aiur.test.reset from inside an agent workspace")
        say("   AIUR_AGENT_WORKSPACE=#{marker}")
        say("   Agents must stop here: do not retry through scripts/aiurdev, /tmp,")
        say("   a copied harness, or another clone.")
        {:error, :agent_workspace_blocked}

      opts.repo_root && String.contains?(opts.repo_root, "/aiur-workspaces/") ->
        say("❌ refusing to run mix aiur.test.reset from inside an agent workspace tree")
        say("   repo_root=#{opts.repo_root}")
        say("   Agents must stop here: do not retry through scripts/aiurdev, /tmp,")
        say("   a copied harness, or another clone.")
        {:error, :agent_workspace_blocked}

      true ->
        :ok
    end
  end

  # `--test` resets only the first pinned ticket (issue 99); `--test3`
  # resets the whole blocker chain. Both share the per-ticket reset
  # path — single mode just narrows the set to one.
  defp dispatch_reset(tickets_data, %{single: true} = opts) do
    with {:ok, tickets} <- validate_pinned_tickets(tickets_data),
         :ok <- guard_clean_git(opts),
         :ok <- guard_expected_remote(tickets_data, opts),
         :ok <- guard_baseline_committed(opts.repo_root) do
      maybe_execute(Enum.take(tickets, 1), opts)
    end
  end

  defp dispatch_reset(tickets_data, opts) do
    with {:ok, tickets} <- validate_pinned_tickets(tickets_data),
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
      single: Map.get(opts, :single, false),
      repo_root: Map.get(opts, :repo_root, File.cwd!())
    }
  end

  defp read_tickets_file(repo_root) do
    path = Path.join(repo_root, @tickets_file)

    case JsonStore.read(path) do
      {:ok, nil} ->
        abort("#{@tickets_file} not found at #{path}")
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
    abort(
      "#{@tickets_file} has no tickets. " <>
        "Populate `tickets: [<id1>, <id2>, <id3>]` after creating the 3 sandbox tickets " <>
        "with `gh issue create ...`. See aiur skill docs for the runbook."
    )

    {:error, :no_tickets_pinned}
  end

  defp validate_pinned_tickets(%{"tickets" => tickets}) when is_list(tickets) do
    case Enum.reject(tickets, &valid_ticket_id?/1) do
      [] ->
        {:ok, Enum.map(tickets, &normalize_id/1)}

      invalid ->
        abort("invalid ticket ids in #{@tickets_file}: #{inspect(invalid)}")
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
        abort(
          "working tree is not clean.\n" <>
            output <> "\nCommit/stash changes or re-run with --force."
        )

        {:error, :dirty_working_tree}

      {output, _} ->
        abort("git status failed: #{output}")
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
          abort(
            "git remote mismatch.\n" <>
              "  expected: #{expected}\n" <>
              "  actual:   #{actual}\n" <>
              "Re-run with --allow-remote if you're sure."
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
        abort(
          "sandbox baseline missing from HEAD: #{inspect(missing)}\n" <>
            "Commit U24's baseline files first."
        )

        {:error, {:baseline_missing, missing}}
    end
  end

  defp maybe_execute(tickets, %{confirm: false}) do
    say("--test DRY-RUN. Pass --confirm to execute.\n")
    print_plan(tickets)
    :ok
  end

  defp maybe_execute(tickets, %{confirm: true} = opts) do
    say("🧪 aiur resetting sandbox (#{length(tickets)} ticket(s))")

    with {:ok, open_tickets} <- prepare_reset_tickets(tickets) do
      results = Enum.map(open_tickets, &reset_one(&1, opts))
      Cleanup.restore_baseline(opts, @baseline_files)
      ensure_opencode_theme()

      case unlabeled_tickets(results) do
        [] ->
          say("✅ sandbox reset complete")
          :ok

        failed_ids ->
          abort(
            "could not label #{inspect(failed_ids, charlists: :as_lists)} as agent:todo after retries — " <>
              "refusing to launch a run that can't dispatch these tickets"
          )

          {:error, {:labels_unset, failed_ids}}
      end
    end
  end

  defp unlabeled_tickets(results) do
    for {:error, {:label_reset_failed, id, _}} <- results, do: id
  end

  defp prepare_reset_tickets(tickets) do
    runner = fn argv -> HostCommand.run(argv, stderr_to_stdout: true, bot_token: true) end

    {open_tickets, blocked_tickets} =
      Enum.reduce(tickets, {[], []}, fn id, {open, blocked} ->
        case prepare_reset_ticket(id, runner) do
          :open ->
            {[id | open], blocked}

          {:closed, _labels} ->
            {open, [id | blocked]}

          {:error, reason} ->
            warn("##{id} state check failed: #{reason}")
            {open, [id | blocked]}
        end
      end)

    case blocked_tickets do
      [] ->
        {:ok, Enum.reverse(open_tickets)}

      ids ->
        blocked = Enum.reverse(ids)

        abort(
          "sandbox ticket(s) must be open before reset: #{inspect(blocked, charlists: :as_lists)}. " <>
            "Reopen them or update #{@tickets_file}; closed tickets were skipped and " <>
            "any detected automation labels were removed."
        )

        {:error, {:tickets_not_open, blocked}}
    end
  end

  # Install + activate the aiur opencode theme so command/tool
  # blockquotes render dim. Idempotent — re-running `aiur --test`
  # is a no-op once the theme is in place and active. Respects any
  # custom theme the user has selected (won't overwrite).
  defp ensure_opencode_theme do
    case Aiur.OpencodeTheme.ensure_active() do
      {:ok, :active} ->
        ok("opencode theme `aiur` active (dim blockquotes)")

      {:ok, :custom_theme_preserved} ->
        warn("opencode theme setup skipped (custom theme preserved)")

      {:skipped, failures} ->
        warn("opencode theme setup skipped (optional; #{theme_failure_summary(failures)})")
    end
  end

  defp theme_failure_summary(failures) do
    failures
    |> Enum.map_join("; ", fn
      {:themes_dir, path, reason} -> "themes dir #{path}: #{inspect(reason)}"
      {:theme_copy, path, reason} -> "theme file #{path}: #{inspect(reason)}"
      {:kv_read, path, reason} -> "state file #{path}: #{inspect(reason)}"
      {:kv_dir, path, reason} -> "state dir #{path}: #{inspect(reason)}"
      {:kv_write, path, reason} -> "state file #{path}: #{inspect(reason)}"
    end)
  end

  defp print_plan(tickets) do
    say("Tickets to reset:")
    Enum.each(tickets, fn id -> say("  - #{id}") end)

    say("\nPer-ticket actions:")
    say("  - Delete subscriptions file for <id>")
    say("  - Remove repo-namespaced workspace for <id> (fans across worker.ssh_hosts)")
    say("  - Delete remote branch aiur/<id>")
    say("  - Close any open PR from aiur/<id>")
    say("  - Delete agent-workpad comments (`## Agent Workpad` bodies) on the issue")
    say("  - If open: strip every agent:* label, re-add agent:todo")
    say("  - If closed: remove detected agent:*/model:* labels and abort before launch")
    say("\nAlways:")
    say("  - Restore sandbox baseline (git checkout HEAD -- " <> Enum.join(@baseline_files, " "))
    say("  - Preserve event-id.json (IdGenerator counter)")
  end

  defp reset_one(id, _opts) do
    Cleanup.delete_subscriptions_file(id)
    Cleanup.delete_workspace(id)
    Cleanup.delete_remote_branch(id)
    Cleanup.close_open_pr(id)
    Cleanup.delete_workpad_comments(id)
    Tickets.reset_labels(id)
  end

  @doc """
  Verifies a pinned sandbox ticket is open before normal reset work.

  Closed tickets are skipped from reset and any observed `agent:*` or
  `model:*` labels are removed so stale automation state is not left on
  closed issues. `runner` is injected for tests and has the same argv
  shape as `System.cmd("gh", argv, ...)`.
  """
  @spec prepare_reset_ticket(integer() | String.t(), gh_runner()) ::
          :open | {:closed, [String.t()]} | {:error, String.t()}
  defdelegate prepare_reset_ticket(id, runner), to: Tickets

  @spec issue_metadata_command_args(integer() | String.t()) :: [String.t()]
  defdelegate issue_metadata_command_args(id), to: Tickets

  @spec automation_label_cleanup_command_args(integer() | String.t(), [String.t()]) ::
          [String.t()] | nil
  defdelegate automation_label_cleanup_command_args(id, labels), to: Tickets

  @spec automation_labels([term()]) :: [String.t()]
  defdelegate automation_labels(labels), to: Tickets

  @doc """
  Run the remove-then-add label pair through `runner`, retrying the pair up to
  `attempts` times on any non-zero `gh` exit. Returns `:ok` once both calls
  succeed, or `{:error, last_output}` after the final attempt fails.

  `runner` is an argv -> `{output, exit_code}` function (injected so the
  retry/abort contract can be tested without shelling out to real `gh`).
  IO-free by design: callers handle logging.
  """

  @spec apply_label_reset([String.t()], [String.t()], gh_runner(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, String.t()}
  defdelegate apply_label_reset(remove_argv, add_argv, runner, attempts, backoff_ms), to: Tickets

  @doc """
  Pure helper returning the argv pair (`--remove-label …`, then
  `--add-label agent:todo`) used by `reset_labels/1`. Exposed so tests
  can lock in the two-call contract that prevents GitHub from stripping
  `agent:todo` when remove and add target the same label in a single
  invocation.
  """
  @spec reset_labels_command_args(integer() | String.t()) :: [[String.t()]]
  defdelegate reset_labels_command_args(id), to: Tickets

  @doc """
  Predicate identifying an agent-workpad comment. The canonical shape
  is a comment whose body starts with `## Agent Workpad` (optionally
  preceded by whitespace). Mid-body references to the workpad header
  in a human review comment must NOT match — only the leading-header
  form is a workpad.
  """
  @spec workpad_comment?(map()) :: boolean()
  defdelegate workpad_comment?(comment), to: Cleanup

  @doc false
  @spec remove_workspace(integer() | String.t(), Path.t()) :: :ok
  defdelegate remove_workspace(id, root), to: Cleanup

  defp say(msg), do: IO.puts(:stderr, msg)

  @doc false
  @spec ok(String.t()) :: :ok
  def ok(msg), do: say("✅ #{msg}")

  @doc false
  @spec warn(String.t()) :: :ok
  def warn(msg), do: say("⚠️  #{msg}")

  defp abort(msg) do
    say("❌ --test ABORT: #{msg}")
    Logger.error("--test ABORT: #{msg}")
  end
end
