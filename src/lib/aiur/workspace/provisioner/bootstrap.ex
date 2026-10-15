defmodule Aiur.Workspace.Provisioner.Bootstrap do
  @moduledoc false

  # Readiness, log-safe reconstruction and prewarm materialization share the
  # same filesystem safety decisions and reconstruction lock.
  alias Aiur.{Config, RepoBase}
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.Workspace.{Checkout, Materialize, Reconstruction, Remote}

  @remote_workspace_marker "__AIUR_WORKSPACE__"
  @workspace_ready_marker ".claude/.aiur-workspace-ready"

  @doc false
  @spec logs_only_workspace?(Path.t(), String.t() | nil) :: boolean()
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
  @spec workspace_ready_marker_path(Path.t()) :: Path.t()
  def workspace_ready_marker_path(workspace) when is_binary(workspace),
    do: Path.join(workspace, @workspace_ready_marker)

  defp create_workspace(workspace) do
    cold_fallback_workspace(workspace)
  end

  @spec force_recreate_workspace(Path.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def force_recreate_workspace(workspace, branch_name, pr_head_ref) do
    Reconstruction.with_log_lock(workspace, fn ->
      replace_workspace(workspace, branch_name, pr_head_ref)
    end)
  end

  defp replace_workspace(workspace, branch_name, pr_head_ref) do
    File.rm_rf!(workspace)

    case create_or_materialize(workspace, branch_name, pr_head_ref) do
      {:ok, _workspace, _created?} -> :ok
      {:error, _reason} = error -> error
    end
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

  @spec ensure_bootstrap_workspace(Path.t(), String.t(), String.t() | nil, map() | nil, map() | nil) ::
          {:ok, Path.t(), boolean() | :materialized} | {:error, term()}
  def ensure_bootstrap_workspace(workspace, branch_name, pr_head_ref, lifecycle, start_point) do
    Reconstruction.with_log_lock(workspace, fn ->
      ensure_bootstrap_workspace_locked(workspace, branch_name, pr_head_ref, lifecycle, start_point)
    end)
  end

  defp ensure_bootstrap_workspace_locked(workspace, branch_name, pr_head_ref, lifecycle, start_point) do
    case workspace_readiness(workspace) do
      :ready ->
        record_prewarm_point(lifecycle, :existing, :skipped)
        {:ok, workspace, false}

      :bootstrap ->
        bootstrap_workspace(workspace, branch_name, pr_head_ref, lifecycle, start_point)

      {:error, _reason} = error ->
        error
    end
  end

  defp bootstrap_workspace(workspace, branch_name, pr_head_ref, lifecycle, start_point) do
    cond do
      File.dir?(workspace) ->
        record_prewarm_point(lifecycle, :incomplete, :rebuild)
        {:ok, workspace, true}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_or_materialize(workspace, branch_name, pr_head_ref, lifecycle, start_point)

      true ->
        create_or_materialize(workspace, branch_name, pr_head_ref, lifecycle, start_point)
    end
  end

  @spec git_metadata_present?(Path.t()) :: boolean()
  def git_metadata_present?(workspace), do: File.exists?(Path.join(workspace, ".git"))

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
  @spec remote_workspace_prepare_script(Path.t()) :: String.t()
  def remote_workspace_prepare_script(workspace) do
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

  # A ready prewarm base carries build artifacts; otherwise use the cold hook path.
  defp create_or_materialize(workspace, branch_name, pr_head_ref, lifecycle \\ nil, start_point \\ nil) do
    case prewarm_base() do
      {:ready, base} ->
        record_prewarm(lifecycle, :start, %{prewarm_outcome: :materialized})

        case Materialize.materialize_from_base(base, workspace, branch_name, pr_head_ref, start_point) do
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

  @spec record_prewarm_point(map() | nil, atom(), atom()) :: term()
  def record_prewarm_point(lifecycle, prewarm_outcome, outcome) do
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
end
