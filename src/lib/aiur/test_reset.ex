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
  src/lib/aiur/sandbox/`) — refuses if HEAD doesn't contain the
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
  # and ports away from the operator instance. Keeping this guard here protects
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
      restore_baseline(opts)
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
    runner = fn argv -> System.cmd("gh", argv, stderr_to_stdout: true) end

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

  @doc """
  Verifies a pinned sandbox ticket is open before normal reset work.

  Closed tickets are skipped from reset and any observed `agent:*` or
  `model:*` labels are removed so stale automation state is not left on
  closed issues. `runner` is injected for tests and has the same argv
  shape as `System.cmd("gh", argv, ...)`.
  """
  @spec prepare_reset_ticket(integer() | String.t(), gh_runner()) ::
          :open | {:closed, [String.t()]} | {:error, String.t()}
  def prepare_reset_ticket(id, runner) do
    case fetch_issue_metadata(id, runner) do
      {:ok, %{state: state, labels: labels}} ->
        cond do
          open_issue_state?(state) ->
            :open

          closed_issue_state?(state) ->
            clear_closed_ticket_automation_labels(id, labels, runner)

          true ->
            {:error, "unexpected GitHub issue state #{inspect(state)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec issue_metadata_command_args(integer() | String.t()) :: [String.t()]
  def issue_metadata_command_args(id) do
    ["issue", "view", to_string(id), "--json", "state,labels"]
  end

  @spec automation_label_cleanup_command_args(integer() | String.t(), [String.t()]) ::
          [String.t()] | nil
  def automation_label_cleanup_command_args(id, labels) do
    case automation_labels(labels) do
      [] -> nil
      automation -> ["issue", "edit", to_string(id), "--remove-label", Enum.join(automation, ",")]
    end
  end

  @spec automation_labels([term()]) :: [String.t()]
  def automation_labels(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(fn label ->
      case label_name(label) do
        "agent:" <> _ = name -> [name]
        "model:" <> _ = name -> [name]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  def automation_labels(_), do: []

  defp fetch_issue_metadata(id, runner) do
    case runner.(issue_metadata_command_args(id)) do
      {output, 0} ->
        decode_issue_metadata(output)

      {output, _code} ->
        {:error, String.trim(to_string(output))}
    end
  end

  defp decode_issue_metadata(output) do
    case Jason.decode(output) do
      {:ok, %{"state" => state} = data} ->
        labels = Map.get(data, "labels", []) |> Enum.flat_map(&metadata_label_name/1)
        {:ok, %{state: state, labels: labels}}

      {:ok, _} ->
        {:error, "could not parse GitHub issue metadata"}

      {:error, _reason} ->
        {:error, "could not parse GitHub issue metadata"}
    end
  end

  defp metadata_label_name(%{"name" => name}) when is_binary(name), do: [name]
  defp metadata_label_name(name) when is_binary(name), do: [name]
  defp metadata_label_name(_), do: []

  defp label_name(%{"name" => name}) when is_binary(name), do: name
  defp label_name(name) when is_binary(name), do: name
  defp label_name(_), do: nil

  defp open_issue_state?(state), do: normalize_issue_state(state) == "open"
  defp closed_issue_state?(state), do: normalize_issue_state(state) == "closed"

  defp normalize_issue_state(state) do
    state
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp clear_closed_ticket_automation_labels(id, labels, runner) do
    case automation_label_cleanup_command_args(id, labels) do
      nil ->
        warn("##{id} closed ticket skipped; no automation labels found")
        {:closed, []}

      argv ->
        automation = automation_labels(labels)

        case runner.(argv) do
          {_, 0} ->
            warn("##{id} closed ticket skipped; removed automation labels: #{Enum.join(automation, ",")}")
            {:closed, automation}

          {output, _code} ->
            {:error, "closed ticket automation label cleanup failed: #{String.trim(to_string(output))}"}
        end
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
    say("  - Remove workspace at <workspace_root>/<id> (fans across worker.ssh_hosts)")
    say("  - Delete remote branch aiur/<id>")
    say("  - Close any open PR from aiur/<id>")
    say("  - Delete agent-workpad comments (`## Agent Workpad` bodies) on the issue")
    say("  - If open: strip every agent:* label, re-add agent:todo")
    say("  - If closed: remove detected agent:*/model:* labels and abort before launch")
    say("\nAlways:")
    say("  - Restore sandbox baseline (git checkout HEAD -- " <> Enum.join(@baseline_files, " "))
    say("  - Preserve <repo>.event_id (IdGenerator counter)")
  end

  defp reset_one(id, _opts) do
    delete_subscriptions_file(id)
    delete_workspace(id)
    delete_remote_branch(id)
    close_open_pr(id)
    delete_workpad_comments(id)
    reset_labels(id)
  end

  # The agent records its plan/handoff state as a comment on the issue
  # whose body starts with `## Agent Workpad`. `aiur --test` previously
  # left these alone, so each fresh sandbox run started with the
  # previous run's workpad sitting in the issue — agents would dutifully
  # reconcile against it instead of treating the ticket as a clean slate.
  defp delete_workpad_comments(id) do
    case System.cmd(
           "gh",
           ["api", "repos/{owner}/{repo}/issues/#{id}/comments", "--paginate"],
           stderr_to_stdout: true
         ) do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, comments} when is_list(comments) ->
            delete_each_workpad(id, Enum.filter(comments, &workpad_comment?/1))

          _ ->
            warn("##{id} workpad scan: could not parse `gh api` JSON")
        end

      {output, _} ->
        warn("##{id} workpad scan failed: #{String.trim(output)}")
    end
  end

  defp delete_each_workpad(id, []) do
    ok("##{id} workpad clear (no comments to remove)")
  end

  defp delete_each_workpad(id, comments) do
    failures =
      Enum.reduce(comments, 0, fn comment, acc ->
        case System.cmd(
               "gh",
               [
                 "api",
                 "-X",
                 "DELETE",
                 "repos/{owner}/{repo}/issues/comments/#{Map.get(comment, "id")}"
               ],
               stderr_to_stdout: true
             ) do
          {_, 0} -> acc
          {_, _} -> acc + 1
        end
      end)

    count = length(comments)

    if failures == 0 do
      ok("##{id} workpad comments removed (#{count})")
    else
      warn("##{id} workpad comments: #{count - failures}/#{count} removed; #{failures} failed")
    end
  end

  @doc """
  Predicate identifying an agent-workpad comment. The canonical shape
  is a comment whose body starts with `## Agent Workpad` (optionally
  preceded by whitespace). Mid-body references to the workpad header
  in a human review comment must NOT match — only the leading-header
  form is a workpad.
  """
  @spec workpad_comment?(map()) :: boolean()
  def workpad_comment?(%{"body" => body}) when is_binary(body) do
    String.starts_with?(String.trim_leading(body), "## Agent Workpad")
  end

  def workpad_comment?(_), do: false

  defp delete_subscriptions_file(id) do
    path = subscriptions_path(id)

    case File.rm(path) do
      :ok -> ok("##{id} subscriptions cleared")
      {:error, :enoent} -> :ok
      {:error, reason} -> warn("##{id} subscriptions clear failed: #{inspect(reason)}")
    end
  end

  # Per-issue workspace clone (typically <workspace_root>/<id>) carries
  # the agent's uncommitted edits, untracked files, and git state from
  # the prior session. Without this, the agent on the next run starts
  # in a dirty tree and reports "I see uncommitted changes" — exactly
  # the symptom the operator hit. Fans out across `worker.ssh_hosts`
  # when configured.
  #
  # We don't go through `Aiur.Workspace.remove_issue_workspaces/1`
  # because that calls `Aiur.Config.settings!()` which requires
  # .aiurconfig to be present and parseable — the reset task runs
  # outside any orchestrator boot, so it may not have a workflow
  # context. Instead we compute the workspace root from
  # `Aiur.Config.workspace_root/0` if available; if not, fall back
  # to the same default `Aiur.Config.Schema.Workspace` uses
  # (`<tmp_dir>/aiur_workspaces`).
  defp delete_workspace(id) do
    root = workspace_root_with_fallback()
    safe_id = Paths.sanitize(to_string(id))
    path = Path.join(root, safe_id)

    case File.rm_rf(path) do
      {:ok, []} ->
        ok("##{id} workspace already clean")

      {:ok, _} ->
        ok("##{id} workspace removed")

      {:error, reason, file} ->
        warn("##{id} workspace cleanup failed at #{file}: #{inspect(reason)}")
    end
  end

  defp workspace_root_with_fallback do
    # Config.workspace_root/0 returns the raw YAML value — when the
    # operator wrote `~/code/aiur-workspaces`, that's what we get.
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

  defp delete_remote_branch(id) do
    # Agents sometimes create suffix-variant branches (e.g.,
    # `aiur/99-event-flow-1`) instead of the canonical `aiur/<id>`. The
    # reset has to delete ALL of them so a re-run starts clean. Walk
    # remote refs matching `aiur/<id>` AND `aiur/<id>-*`.
    branches = list_remote_branches_for(id)

    if branches == [] do
      ok("##{id} remote branch already gone")
    else
      Enum.each(branches, &delete_one_remote_branch(id, &1))
    end
  end

  defp list_remote_branches_for(id) do
    pattern = "refs/heads/aiur/#{id}*"

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

  # `git ls-remote --heads origin refs/heads/aiur/99*` could match
  # `aiur/999` (different ticket). Tighten to exact + dash-suffix.
  defp filter_id_match(id, "aiur/" <> rest) do
    cond do
      rest == to_string(id) -> ["aiur/#{id}"]
      String.starts_with?(rest, "#{id}-") -> ["aiur/#{rest}"]
      true -> []
    end
  end

  defp filter_id_match(_id, _branch), do: []

  defp delete_one_remote_branch(id, branch) do
    case System.cmd("git", ["push", "origin", "--delete", branch], stderr_to_stdout: true) do
      {_, 0} ->
        ok("##{id} remote branch #{branch} deleted")

      {output, _} ->
        if String.contains?(output, "remote ref does not exist") do
          :ok
        else
          warn("##{id} remote branch #{branch}: #{String.trim(output)}")
        end
    end
  end

  defp close_open_pr(id) do
    # Close PRs targeting any branch in `aiur/<id>` and any `aiur/<id>-*`
    # suffix variant. `gh pr close <branch>` resolves the branch name to
    # the open PR head; safe to call when no PR exists (silent no-op).
    case list_remote_branches_for(id) do
      [] -> close_pr_for_branch(id, "aiur/#{id}")
      branches -> Enum.each(branches, &close_pr_for_branch(id, &1))
    end
  end

  defp close_pr_for_branch(id, branch) do
    case System.cmd("gh", ["pr", "close", branch, "--delete-branch=false"], stderr_to_stdout: true) do
      {_, 0} -> ok("##{id} PR on #{branch} closed")
      {_, _} -> :ok
    end
  end

  # Strip every agent:* label and re-add agent:todo so the orchestrator
  # treats the issue as queued on the next dispatch poll. Without this,
  # tickets that the previous run flipped to agent:in-progress (or
  # agent:human-review, agent:done) stay in that state and either
  # never re-enter the dispatch set or skip the queue logic entirely.
  #
  # Issue this as TWO `gh` calls: one to strip every agent:* label,
  # then one to add agent:todo. The combined form
  # `gh issue edit N --remove-label "agent:todo,…" --add-label "agent:todo"`
  # is unsafe — when the same label appears in both the remove and add
  # sets, GitHub's PATCH ordering resolves the remove last, stripping
  # the label entirely. That left issues in an unlabeled state, which
  # made the orchestrator skip dispatching them and the user's chat
  # pane render no agent text (no codex turn → no transcript events).
  # GitHub's GraphQL endpoint intermittently 401s during a reset (and its
  # label index lags), so a single `gh issue edit` attempt is flaky. When it
  # fails, the ticket is left without `agent:todo` and the orchestrator never
  # dispatches it — for the 3-ticket blocker chain that strands the whole run
  # (e.g. #101 opens its PR then pauses forever waiting on the never-dispatched
  # #100, timing out ~90 min later). Retry a few times, then return an error so
  # the caller refuses to launch a run that can't dispatch this ticket.
  @label_reset_attempts 3
  @label_reset_backoff_ms 1_500

  defp reset_labels(id) do
    [remove_argv, add_argv] = reset_labels_command_args(id)
    runner = fn argv -> System.cmd("gh", argv, stderr_to_stdout: true) end

    case apply_label_reset(remove_argv, add_argv, runner, @label_reset_attempts, @label_reset_backoff_ms) do
      :ok ->
        ok("##{id} labels prepared on open ticket → agent:todo")
        :ok

      {:error, output} ->
        warn("##{id} label reset FAILED after #{@label_reset_attempts} attempts: #{output}")
        {:error, {:label_reset_failed, id, output}}
    end
  end

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
  def apply_label_reset(remove_argv, add_argv, runner, attempts, backoff_ms)
      when attempts > 0 do
    with {_, 0} <- runner.(remove_argv),
         {_, 0} <- runner.(add_argv) do
      :ok
    else
      {_output, _code} when attempts > 1 ->
        if backoff_ms > 0, do: Process.sleep(backoff_ms)
        apply_label_reset(remove_argv, add_argv, runner, attempts - 1, backoff_ms)

      {output, _code} ->
        {:error, String.trim(to_string(output))}
    end
  end

  @doc """
  Pure helper returning the argv pair (`--remove-label …`, then
  `--add-label agent:todo`) used by `reset_labels/1`. Exposed so tests
  can lock in the two-call contract that prevents GitHub from stripping
  `agent:todo` when remove and add target the same label in a single
  invocation.
  """
  @spec reset_labels_command_args(integer() | String.t()) :: [[String.t()]]
  def reset_labels_command_args(id) do
    agent_labels =
      "agent:todo,agent:in-progress,agent:ci-wait,agent:human-review,agent:rework,agent:merging,agent:done,agent:error,agent:cancelled,agent:canceled,agent:paused"

    [
      ["issue", "edit", to_string(id), "--remove-label", agent_labels],
      ["issue", "edit", to_string(id), "--add-label", "agent:todo"]
    ]
  end

  defp restore_baseline(opts) do
    # If the operator passed --force AND any sandbox file has uncommitted
    # local changes, stash them first so destructive checkout doesn't
    # silently lose work.
    if opts.force, do: stash_sandbox_if_dirty(opts)

    args = ["checkout", "HEAD", "--"] ++ @baseline_files

    case System.cmd("git", args, stderr_to_stdout: true, cd: opts.repo_root) do
      {_, 0} -> ok("sandbox baseline restored")
      {output, code} -> warn("baseline restore exit=#{code}: #{output}")
    end
  end

  defp stash_sandbox_if_dirty(opts) do
    args = ["status", "--porcelain", "--"] ++ @baseline_files

    case System.cmd("git", args, stderr_to_stdout: true, cd: opts.repo_root) do
      {"", _} ->
        :ok

      {dirty, _} ->
        warn(
          "--force with uncommitted sandbox edits:\n" <>
            dirty <>
            "Stashing before checkout."
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

  defp say(msg), do: IO.puts(:stderr, msg)
  defp ok(msg), do: say("✅ #{msg}")
  defp warn(msg), do: say("⚠️  #{msg}")

  defp abort(msg) do
    say("❌ --test ABORT: #{msg}")
    Logger.error("--test ABORT: #{msg}")
  end
end
