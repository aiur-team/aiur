defmodule Aiur.Workspace.Provisioner do
  @moduledoc """
  Provisions local and remote workspaces, including prewarm materialization and
  stale workspace recreation.
  """

  require Logger
  alias Aiur.{Config, RepoBase, TicketBranch, Tracker}
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.Workspace.{Checkout, Context, Materialize, Reconstruction, Remote}

  @remote_workspace_marker "__AIUR_WORKSPACE__"
  @remote_agent_support_modules [Aiur.AgentSkills, Aiur.AgentGitHubGuard, Aiur.AgentScratch]
  @local_agent_support_modules [Aiur.AgentSkills, Aiur.AgentGitHubGuard, Aiur.AgentBuildGuard, Aiur.AgentScratch]
  @remote_workspace_ready_marker "__AIUR_WORKSPACE_READY__"
  @workspace_ready_marker ".claude/.aiur-workspace-ready"

  @doc false
  # Install aiur's bundled agent-operating skills and command guards into a
  # freshly populated workspace. Remote workers receive the portable subset
  # through one idempotent SSH script; build admission is currently local-only.
  @spec maybe_install_agent_support(Path.t(), String.t() | nil) :: :ok | {:error, term()}
  def maybe_install_agent_support(workspace, nil) do
    Enum.reduce_while(@local_agent_support_modules, :ok, fn module, :ok ->
      case module.install(workspace) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def maybe_install_agent_support(workspace, worker_host) when is_binary(worker_host) do
    maybe_install_agent_support(workspace, worker_host, &Remote.run_remote_script/3)
  end

  @doc false
  @spec maybe_install_agent_support(Path.t(), String.t(), (String.t(), String.t(), pos_integer() -> term())) ::
          :ok | {:error, term()}
  def maybe_install_agent_support(workspace, worker_host, runner)
      when is_binary(workspace) and is_binary(worker_host) and is_function(runner, 3) do
    script = remote_agent_support_script(workspace, worker_host)

    case runner.(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      result ->
        Logger.warning("remote agent support install failed worker_host=#{worker_host} result=#{inspect(result)}")
        {:error, {:remote_agent_support_install_failed, result}}
    end
  end

  # `worker_host` is passed to the modules that accept install options so the
  # host-credential cleanup only ever runs on a genuinely remote install (#2478);
  # the same script executed locally must not touch the operator's own `$HOME`.
  defp remote_agent_support_script(workspace, worker_host) do
    Enum.map_join(@remote_agent_support_modules, "\n", fn module ->
      # `Code.ensure_loaded?/1` first: on a not-yet-loaded module
      # `function_exported?/3` answers false, which would silently fall back to
      # the arity-1 call and drop the remote credential cleanup rather than
      # failing loudly.
      if Code.ensure_loaded?(module) and function_exported?(module, :remote_install_script, 2) do
        module.remote_install_script(workspace, remote_host: worker_host)
      else
        module.remote_install_script(workspace)
      end
    end)
  end

  @type worker_host :: String.t() | nil

  @doc false
  @spec resolve_branch_name(Path.t(), map()) :: String.t()
  def resolve_branch_name(workspace, issue_context) do
    resolve_branch_name(workspace, issue_context, &Tracker.fetch_open_pull_request_for_branch/1)
  end

  @doc false
  @spec resolve_branch_name(Path.t(), map(), (String.t() -> {:ok, map() | nil} | {:error, term()})) ::
          String.t()
  def resolve_branch_name(workspace, issue_context, fetch_open_pull_request)
      when is_binary(workspace) and is_function(fetch_open_pull_request, 1) do
    branch_name = Map.fetch!(issue_context, :branch_name)

    cond do
      pr_head_ref = established_pr_head_ref(issue_context) ->
        pr_head_ref

      current_branch = established_workspace_branch(workspace, branch_name) ->
        current_branch

      Context.todo_dispatch?(issue_context) ->
        branch_name

      pr_branch = established_pull_request_branch(branch_name, fetch_open_pull_request) ->
        pr_branch

      true ->
        branch_name
    end
  end

  @spec ensure_workspace(Path.t(), worker_host(), String.t() | nil) ::
          {:ok, Path.t(), boolean() | :materialized} | {:error, term()}
  # PR-anchored creation (`pr_head_ref` set) is only wired for the local
  # worker today; a remote worker_host ignores it and keeps the legacy
  # `aiur/<id>` remote path byte-for-byte (SSH PR-anchored is out of scope
  # for this unit). The 3-arity entrypoint retains the legacy branch for
  # compatibility; tracker issue contexts use the 4-arity generated branch.
  def ensure_workspace(workspace, worker_host, pr_head_ref),
    do: ensure_workspace(workspace, worker_host, pr_head_ref, legacy_branch_name(workspace))

  @spec ensure_workspace(Path.t(), worker_host(), String.t() | nil, String.t()) ::
          {:ok, Path.t(), boolean() | :materialized} | {:error, term()}
  def ensure_workspace(workspace, worker_host, pr_head_ref, branch_name),
    do: ensure_workspace(workspace, worker_host, pr_head_ref, branch_name, nil)

  @doc false
  @spec ensure_workspace(Path.t(), worker_host(), String.t() | nil, String.t(), map() | nil) ::
          {:ok, Path.t(), boolean() | :materialized} | {:error, term()}
  def ensure_workspace(workspace, nil, pr_head_ref, branch_name, lifecycle)
      when is_binary(branch_name) do
    cond do
      Checkout.valid_workspace?(workspace) ->
        record_prewarm_point(lifecycle, :existing, :skipped)
        {:ok, workspace, false}

      # `created?` is creation telemetry, not a safety verdict. Retain the
      # honest existing-path outcome for an interrupted Git initialization;
      # Workspace.create_for_issue/3 separately rejects it before hooks can
      # stage or replace its contents.
      File.dir?(workspace) and git_metadata_present?(workspace) ->
        record_prewarm_point(lifecycle, :existing, :skipped)
        {:ok, workspace, false}

      true ->
        case workspace_readiness(workspace) do
          :ready ->
            record_prewarm_point(lifecycle, :existing, :skipped)
            {:ok, workspace, false}

          :bootstrap ->
            ensure_bootstrap_workspace(workspace, branch_name, pr_head_ref, lifecycle)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def ensure_workspace(workspace, worker_host, _pr_head_ref, _branch_name, lifecycle)
      when is_binary(worker_host) do
    record_prewarm_point(lifecycle, :remote, :unavailable)
    ensure_workspace(workspace, worker_host)
  end

  @spec ensure_workspace(Path.t(), worker_host()) ::
          {:ok, Path.t(), boolean() | :materialized} | {:error, term()}
  def ensure_workspace(workspace, nil) do
    cond do
      Checkout.valid_workspace?(workspace) ->
        {:ok, workspace, false}

      File.dir?(workspace) and git_metadata_present?(workspace) ->
        {:ok, workspace, false}

      true ->
        case workspace_readiness(workspace) do
          :ready -> {:ok, workspace, false}
          :bootstrap -> ensure_bootstrap_workspace(workspace, legacy_branch_name(workspace), nil, nil)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    case Remote.run_remote_command(
           worker_host,
           remote_workspace_prepare_script(workspace),
           Config.settings!().hooks.timeout_ms
         ) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Event logging can create a `logs/` directory before provisioning starts.
  # Only empty and logs-only directories are safe to bootstrap without a prior
  # completion record. In particular, an unborn Git repository can satisfy
  # `--show-toplevel` yet have no checkout to recover; treating it as scratch
  # would discard any interrupted bootstrap or user WIP.
  @doc false
  @spec incomplete_workspace?(Path.t()) :: boolean()
  def incomplete_workspace?(workspace) when is_binary(workspace),
    do: workspace_readiness(workspace) == :bootstrap

  def incomplete_workspace?(_workspace), do: true

  @doc false
  @spec logs_only_workspace?(Path.t(), worker_host()) :: boolean()
  def logs_only_workspace?(workspace, nil) when is_binary(workspace) do
    case File.ls(workspace) do
      {:ok, ["logs"]} -> safe_logs_tree?(Path.join(workspace, "logs")) == :ok
      _ -> false
    end
  end

  # Remote preparation rejects unproven non-empty directories before hooks
  # run, so this local-only check need not attempt a second SSH inspection.
  def logs_only_workspace?(_workspace, worker_host) when is_binary(worker_host), do: false

  @doc false
  @spec workspace_readiness(Path.t()) :: :ready | :bootstrap | {:error, term()}
  def workspace_readiness(workspace) when is_binary(workspace) do
    cond do
      Checkout.valid_workspace?(workspace) ->
        :ready

      File.dir?(workspace) and git_metadata_present?(workspace) ->
        {:error, {:workspace_ambiguous, workspace, :invalid_git_checkout}}

      File.regular?(workspace_ready_marker_path(workspace)) ->
        :ready

      File.dir?(workspace) ->
        empty_or_logs_only_workspace(workspace)

      true ->
        :bootstrap
    end
  end

  def workspace_readiness(_workspace), do: {:error, :invalid_workspace_path}

  @doc false
  @spec ensure_workspace_usable(Path.t(), worker_host(), boolean() | :materialized) ::
          :ok | {:error, term()}
  def ensure_workspace_usable(_workspace, _worker_host, true), do: :ok
  def ensure_workspace_usable(_workspace, _worker_host, :materialized), do: :ok

  def ensure_workspace_usable(workspace, nil, false) do
    case workspace_readiness(workspace) do
      :ready -> :ok
      :bootstrap -> {:error, {:workspace_ambiguous, workspace, :unproven_contents}}
      {:error, _reason} = error -> error
    end
  end

  def ensure_workspace_usable(workspace, worker_host, false) when is_binary(worker_host) do
    case remote_workspace_readiness(workspace, worker_host) do
      :ready -> :ok
      :bootstrap -> {:error, {:workspace_ambiguous, workspace, :unproven_contents}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec workspace_ready_marker_path(Path.t()) :: Path.t()
  def workspace_ready_marker_path(workspace) when is_binary(workspace),
    do: Path.join(workspace, @workspace_ready_marker)

  @doc false
  @spec mark_workspace_ready(Path.t(), worker_host()) :: :ok | {:error, term()}
  def mark_workspace_ready(workspace, nil) when is_binary(workspace) do
    if Checkout.valid_workspace?(workspace) do
      :ok
    else
      marker = workspace_ready_marker_path(workspace)

      with :ok <- File.mkdir_p(Path.dirname(marker)),
           :ok <- File.write(marker, "ready\n"),
           {:ok, file} <- File.open(marker, [:read, :raw]) do
        try do
          case :file.sync(file) do
            :ok -> :ok
            {:error, reason} -> {:error, {:workspace_completion_marker_failed, workspace, reason}}
          end
        after
          File.close(file)
        end
      else
        {:error, reason} -> {:error, {:workspace_completion_marker_failed, workspace, reason}}
      end
    end
  end

  def mark_workspace_ready(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        Remote.remote_shell_assign("workspace", workspace),
        "printf 'ready\\n' > \"$workspace/#{@workspace_ready_marker}\""
      ]
      |> Enum.join("\n")

    case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:workspace_completion_marker_failed, workspace, worker_host, status, output}}
      {:error, reason} -> {:error, {:workspace_completion_marker_failed, workspace, worker_host, reason}}
    end
  end

  @doc false
  @spec bootstrap_required?(Path.t(), worker_host(), boolean() | :materialized) :: boolean()
  def bootstrap_required?(_workspace, _worker_host, true), do: true
  def bootstrap_required?(_workspace, _worker_host, :materialized), do: false

  def bootstrap_required?(_workspace, nil, false), do: false
  def bootstrap_required?(_workspace, worker_host, false) when is_binary(worker_host), do: false

  @doc false
  @spec parse_remote_workspace_output(iodata()) ::
          {:ok, Path.t(), boolean()} | {:error, term()}
  def parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  @spec recreate(Path.t(), worker_host()) :: :ok | {:error, term()}
  def recreate(workspace, nil), do: force_recreate_workspace(workspace, legacy_branch_name(workspace), nil)

  def recreate(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        Remote.remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\"",
        "mkdir -p \"$workspace\""
      ]
      |> Enum.join("\n")

    case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:workspace_prepare_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec recreate(Path.t(), worker_host(), String.t() | nil, String.t()) :: :ok | {:error, term()}
  def recreate(workspace, nil, pr_head_ref, branch_name) when is_binary(branch_name) do
    force_recreate_workspace(workspace, branch_name, pr_head_ref)
  end

  def recreate(workspace, worker_host, _pr_head_ref, _branch_name) when is_binary(worker_host),
    do: recreate(workspace, worker_host)

  defp create_workspace(workspace) do
    cold_fallback_workspace(workspace)
  end

  defp force_recreate_workspace(workspace, branch_name, pr_head_ref) do
    Reconstruction.with_log_lock(workspace, fn ->
      File.rm_rf!(workspace)

      case create_or_materialize(workspace, branch_name, pr_head_ref) do
        {:ok, _workspace, _created?} -> :ok
        {:error, _reason} = error -> error
      end
    end)
  end

  # A materialization failure can race the first transcript event for an
  # otherwise-missing workspace. AgentEventLog uses this same lock, so inspect
  # and create under it instead of deleting a directory that appeared between
  # the failed stage and the cold fallback.
  @doc false
  @spec cold_fallback_workspace(Path.t(), (-> term())) ::
          {:ok, Path.t(), true} | {:error, term()}
  def cold_fallback_workspace(workspace, before_recheck \\ fn -> :ok end)
      when is_binary(workspace) and is_function(before_recheck, 0) do
    Reconstruction.with_log_lock(workspace, fn ->
      before_recheck.()

      case cold_fallback_readiness(workspace) do
        :missing ->
          File.mkdir_p!(workspace)
          {:ok, workspace, true}

        :empty_or_logs_only ->
          {:ok, workspace, true}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp ensure_bootstrap_workspace(workspace, branch_name, pr_head_ref, lifecycle) do
    Reconstruction.with_log_lock(workspace, fn ->
      ensure_bootstrap_workspace_locked(workspace, branch_name, pr_head_ref, lifecycle)
    end)
  end

  defp ensure_bootstrap_workspace_locked(workspace, branch_name, pr_head_ref, lifecycle) do
    case workspace_readiness(workspace) do
      :ready ->
        record_prewarm_point(lifecycle, :existing, :skipped)
        {:ok, workspace, false}

      :bootstrap ->
        bootstrap_workspace(workspace, branch_name, pr_head_ref, lifecycle)

      {:error, _reason} = error ->
        error
    end
  end

  defp bootstrap_workspace(workspace, branch_name, pr_head_ref, lifecycle) do
    cond do
      File.dir?(workspace) ->
        record_prewarm_point(lifecycle, :incomplete, :rebuild)
        {:ok, workspace, true}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_or_materialize(workspace, branch_name, pr_head_ref, lifecycle)

      true ->
        create_or_materialize(workspace, branch_name, pr_head_ref, lifecycle)
    end
  end

  defp git_metadata_present?(workspace), do: File.exists?(Path.join(workspace, ".git"))

  defp empty_or_logs_only_workspace(workspace) do
    case File.ls(workspace) do
      {:ok, []} -> :bootstrap
      {:ok, ["logs"]} -> logs_only_bootstrap_status(workspace)
      {:ok, _entries} -> {:error, {:workspace_ambiguous, workspace, :unproven_contents}}
      {:error, reason} -> {:error, {:workspace_unreadable, workspace, reason}}
    end
  end

  defp logs_only_bootstrap_status(workspace) do
    case safe_logs_tree?(Path.join(workspace, "logs")) do
      :ok -> :bootstrap
      {:error, _reason} -> {:error, {:workspace_ambiguous, workspace, :unproven_contents}}
    end
  end

  defp cold_fallback_readiness(workspace) do
    case File.lstat(workspace) do
      {:error, :enoent} ->
        :missing

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(workspace) do
          {:ok, []} -> :empty_or_logs_only
          {:ok, ["logs"]} -> cold_logs_only_status(workspace)
          {:ok, _entries} -> {:error, {:workspace_cold_fallback_ambiguous, workspace}}
          {:error, reason} -> {:error, {:workspace_unreadable, workspace, reason}}
        end

      {:ok, _stat} ->
        {:error, {:workspace_cold_fallback_ambiguous, workspace}}

      {:error, reason} ->
        {:error, {:workspace_unreadable, workspace, reason}}
    end
  end

  defp cold_logs_only_status(workspace) do
    case safe_logs_tree?(Path.join(workspace, "logs")) do
      :ok -> :empty_or_logs_only
      {:error, _reason} -> {:error, {:workspace_cold_fallback_ambiguous, workspace}}
    end
  end

  # Logs are the only pre-provisioning subtree created by the event writer.
  # A symlink or special node makes the interrupted bootstrap ambiguous rather
  # than letting reconstruction follow an unverified path during promotion.
  defp safe_logs_tree?(path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, entries} <- File.ls(path) do
      safe_logs_entries?(entries, path)
    else
      {:ok, _stat} -> {:error, :logs_not_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_logs_entries?(entries, path) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case safe_logs_entry?(Path.join(path, entry)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp safe_logs_entry?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :directory}} -> safe_logs_tree?(path)
      {:ok, _stat} -> {:error, :unsafe_log_entry}
      {:error, reason} -> {:error, reason}
    end
  end

  # Remote hooks run in place, so an existing non-empty non-checkout cannot be
  # safely staged or atomically promoted from this BEAM. Refuse it before the
  # hook or provider starts; empty paths are still first-time bootstraps, and
  # prior explicit completion markers retain the configured non-Git behavior.
  defp remote_workspace_prepare_script(workspace) do
    [
      "set -eu",
      Remote.remote_shell_assign("workspace", workspace),
      "if [ -d \"$workspace\" ]; then",
      "  current=\"$(cd \"$workspace\" && pwd -P)\"",
      "  git_top=\"$(git -C \"$workspace\" rev-parse --show-toplevel 2>/dev/null || true)\"",
      "  if [ \"$git_top\" = \"$current\" ] && git -C \"$workspace\" rev-parse --verify HEAD >/dev/null 2>&1; then",
      "    created=0",
      "  elif [ -f \"$workspace/.claude/.aiur-workspace-ready\" ]; then",
      "    created=0",
      "  elif [ -z \"$(find \"$workspace\" -mindepth 1 -maxdepth 1 -print -quit)\" ]; then",
      "    created=1",
      "  else",
      "    printf '%s\\t%s\\n' '#{@remote_workspace_marker}' incomplete \"$current\"",
      "    exit 65",
      "  fi",
      "elif [ -e \"$workspace\" ]; then",
      "  rm -rf \"$workspace\"",
      "  mkdir -p \"$workspace\"",
      "  created=1",
      "else",
      "  mkdir -p \"$workspace\"",
      "  created=1",
      "fi",
      "cd \"$workspace\"",
      "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
    ]
    |> Enum.join("\n")
  end

  defp remote_workspace_readiness(workspace, worker_host) do
    script =
      [
        "set -eu",
        Remote.remote_shell_assign("workspace", workspace),
        "current=\"$(cd \"$workspace\" && pwd -P)\"",
        "git_top=\"$(git -C \"$workspace\" rev-parse --show-toplevel 2>/dev/null || true)\"",
        "if [ -f \"$workspace/.claude/.aiur-workspace-ready\" ] || {",
        "  [ \"$git_top\" = \"$current\" ] &&",
        "  git -C \"$workspace\" rev-parse --verify HEAD >/dev/null 2>&1;",
        "}; then",
        "  printf '%s\\n' '#{@remote_workspace_ready_marker}'",
        "else",
        "  exit 65",
        "fi"
      ]
      |> Enum.join("\n")

    case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} when is_binary(output) ->
        if String.contains?(output, @remote_workspace_ready_marker),
          do: :ready,
          else: {:error, {:workspace_prepare_failed, :invalid_output, output}}

      {:ok, {_output, 65}} ->
        :bootstrap

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # When pre-warm is enabled and the shared base is ready, materialize the
  # workspace from it (copy-on-write where the filesystem supports it, carrying
  # the warm `_build`/deps) instead of cold-cloning + recompiling. Anything that
  # rules pre-warm out — disabled, base not ready, missing, or a copy failure —
  # falls through to the unchanged cold `create_workspace/1` path.
  defp create_or_materialize(workspace, branch_name, pr_head_ref, lifecycle \\ nil) do
    case prewarm_base() do
      {:ready, base} ->
        record_prewarm(lifecycle, :start, %{prewarm_outcome: :materialized})

        case Materialize.materialize_from_base(base, workspace, branch_name, pr_head_ref) do
          :ok ->
            record_prewarm(lifecycle, :end, %{
              prewarm_outcome: :materialized,
              outcome: :success
            })

            {:ok, workspace, :materialized}

          {:error, reason} ->
            record_prewarm(lifecycle, :end, %{
              prewarm_outcome: :materialize_failed,
              outcome: :failed,
              reason_class: Lifecycle.reason_class(reason)
            })

            record_prewarm_point(lifecycle, :cold_fallback, :success)
            create_workspace(workspace)
        end

      {:skip, outcome} ->
        record_prewarm_point(lifecycle, outcome, :skipped)
        create_workspace(workspace)
    end
  end

  defp prewarm_base do
    if Config.prewarm_enabled?() do
      ready_prewarm_base()
    else
      {:skip, :disabled}
    end
  end

  defp ready_prewarm_base do
    case RepoBase.status() do
      {:ready, base} when is_binary(base) ->
        if File.dir?(base), do: {:ready, base}, else: {:skip, :cold_base_missing}

      _other ->
        {:skip, :cold_base_not_ready}
    end
  end

  defp record_prewarm_point(lifecycle, prewarm_outcome, outcome) do
    record_prewarm(lifecycle, :point, %{
      prewarm_outcome: prewarm_outcome,
      outcome: outcome
    })
  end

  defp record_prewarm(
         %{ticket: ticket, attempt_id: attempt_id, recorder: recorder},
         boundary,
         metadata
       )
       when is_binary(ticket) and is_function(recorder, 3) do
    Lifecycle.record(ticket, attempt_id, :prewarm, boundary, metadata, recorder: recorder)
  end

  defp record_prewarm(%{ticket: ticket, attempt_id: attempt_id}, boundary, metadata)
       when is_binary(ticket) do
    Lifecycle.record(ticket, attempt_id, :prewarm, boundary, metadata)
  end

  defp record_prewarm(_lifecycle, _boundary, _metadata), do: :ok

  defp established_pr_head_ref(%{pr_head_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp established_pr_head_ref(_issue_context), do: nil

  defp established_workspace_branch(workspace, branch_name) do
    with ticket_id when is_binary(ticket_id) <- TicketBranch.ticket_id(branch_name),
         current_branch when is_binary(current_branch) <- Checkout.current_branch(workspace),
         true <- TicketBranch.ticket_branch?(current_branch, ticket_id) do
      current_branch
    else
      _ -> nil
    end
  end

  defp established_pull_request_branch(branch_name, fetch_open_pull_request) do
    with ticket_id when is_binary(ticket_id) <- TicketBranch.ticket_id(branch_name),
         {:ok, pull_request} when is_map(pull_request) <- fetch_open_pull_request.(ticket_id),
         head_ref when is_binary(head_ref) <- pull_request_head_ref(pull_request),
         true <- TicketBranch.ticket_branch?(head_ref, ticket_id) do
      head_ref
    else
      _ -> nil
    end
  end

  defp pull_request_head_ref(%{"head" => %{"ref" => ref}}) when is_binary(ref), do: ref
  defp pull_request_head_ref(%{head: %{ref: ref}}) when is_binary(ref), do: ref
  defp pull_request_head_ref(_pull_request), do: nil

  defp legacy_branch_name(workspace), do: TicketBranch.legacy_branch_name(Path.basename(workspace))
end
