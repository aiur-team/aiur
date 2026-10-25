defmodule Aiur.Workspace.Provisioner do
  @moduledoc """
  Provisions local and remote workspaces, including prewarm materialization and
  stale workspace recreation.
  """

  alias Aiur.{Config, TicketBranch}
  alias Aiur.Workspace.{Checkout, Context, DirtyGuard, Remote, WipPreservation}
  alias Aiur.Workspace.Provisioner.{AgentSupport, Bootstrap}

  @remote_workspace_marker "__AIUR_WORKSPACE__"
  @remote_workspace_ready_marker "__AIUR_WORKSPACE_READY__"
  @workspace_ready_marker ".claude/.aiur-workspace-ready"

  @doc false
  @spec maybe_install_agent_support(Path.t(), String.t() | nil) :: :ok | {:error, term()}
  defdelegate maybe_install_agent_support(workspace, worker_host), to: AgentSupport

  @doc false
  @spec maybe_install_agent_support(Path.t(), String.t(), (String.t(), String.t(), pos_integer() -> term())) :: :ok | {:error, term()}
  defdelegate maybe_install_agent_support(workspace, worker_host, runner), to: AgentSupport

  @doc false
  @spec ensure_local_agent_support(Path.t()) :: :ok | {:error, term()}
  defdelegate ensure_local_agent_support(workspace), to: AgentSupport

  @doc false
  @spec repair_agent_github_guard(Path.t(), String.t() | nil) :: :ok | {:error, term()}
  defdelegate repair_agent_github_guard(workspace, worker_host), to: AgentSupport

  @doc false
  @spec repair_agent_github_guard(Path.t(), String.t(), (String.t(), String.t(), pos_integer() -> term())) :: :ok | {:error, term()}
  defdelegate repair_agent_github_guard(workspace, worker_host, runner), to: AgentSupport

  @type worker_host :: String.t() | nil

  @doc false
  @spec resolve_branch_name(Path.t(), map()) :: String.t()
  def resolve_branch_name(workspace, issue_context) do
    resolve_branch_name(workspace, issue_context, &Aiur.CodeHost.fetch_open_pull_request_for_branch/1)
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
  # Remote workers retain their hook-owned checkout; optimistic prompts reconcile it.
  def ensure_workspace(workspace, worker_host, pr_head_ref),
    do: ensure_workspace(workspace, worker_host, pr_head_ref, legacy_branch_name(workspace))

  @spec ensure_workspace(Path.t(), worker_host(), String.t() | nil, String.t()) ::
          {:ok, Path.t(), boolean() | :materialized} | {:error, term()}
  def ensure_workspace(workspace, worker_host, pr_head_ref, branch_name),
    do: ensure_workspace(workspace, worker_host, pr_head_ref, branch_name, nil)

  @doc false
  @spec ensure_workspace(Path.t(), worker_host(), String.t() | nil, String.t(), map() | nil) ::
          {:ok, Path.t(), boolean() | :materialized} | {:error, term()}
  def ensure_workspace(workspace, worker_host, pr_head_ref, branch_name, lifecycle),
    do: ensure_workspace(workspace, worker_host, pr_head_ref, branch_name, lifecycle, nil)

  @spec ensure_workspace(Path.t(), worker_host(), String.t() | nil, String.t(), map() | nil, map() | nil) ::
          {:ok, Path.t(), boolean() | :materialized} | {:error, term()}
  def ensure_workspace(workspace, nil, pr_head_ref, branch_name, lifecycle, start_point)
      when is_binary(branch_name) do
    with :ok <- Bootstrap.set_aside_runtime_scratch(workspace) do
      ensure_local_workspace(workspace, pr_head_ref, branch_name, lifecycle, start_point)
    end
  end

  def ensure_workspace(workspace, worker_host, _pr_head_ref, _branch_name, lifecycle, _start_point)
      when is_binary(worker_host) do
    Bootstrap.record_prewarm_point(lifecycle, :remote, :unavailable)
    ensure_workspace(workspace, worker_host)
  end

  defp ensure_local_workspace(workspace, pr_head_ref, branch_name, lifecycle, start_point) do
    cond do
      Checkout.valid_workspace?(workspace) ->
        Bootstrap.record_prewarm_point(lifecycle, :existing, :skipped)
        {:ok, workspace, false}

      # `created?` is creation telemetry, not a safety verdict. Retain the
      # honest existing-path outcome for an interrupted Git initialization;
      # Workspace.create_for_issue/3 separately rejects it before hooks can
      # stage or replace its contents.
      File.dir?(workspace) and Bootstrap.git_metadata_present?(workspace) ->
        Bootstrap.record_prewarm_point(lifecycle, :existing, :skipped)
        {:ok, workspace, false}

      true ->
        case workspace_readiness(workspace) do
          :ready ->
            Bootstrap.record_prewarm_point(lifecycle, :existing, :skipped)
            {:ok, workspace, false}

          :bootstrap ->
            Bootstrap.ensure_bootstrap_workspace(workspace, branch_name, pr_head_ref, lifecycle, start_point)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec ensure_workspace(Path.t(), worker_host()) ::
          {:ok, Path.t(), boolean() | :materialized} | {:error, term()}
  def ensure_workspace(workspace, nil) do
    with :ok <- Bootstrap.set_aside_runtime_scratch(workspace) do
      ensure_local_workspace(workspace)
    end
  end

  def ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    case Remote.run_remote_command(
           worker_host,
           Bootstrap.remote_workspace_prepare_script(workspace),
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

  defp ensure_local_workspace(workspace) do
    cond do
      Checkout.valid_workspace?(workspace) ->
        {:ok, workspace, false}

      File.dir?(workspace) and Bootstrap.git_metadata_present?(workspace) ->
        {:ok, workspace, false}

      true ->
        case workspace_readiness(workspace) do
          :ready -> {:ok, workspace, false}
          :bootstrap -> Bootstrap.ensure_bootstrap_workspace(workspace, legacy_branch_name(workspace), nil, nil, nil)
          {:error, reason} -> {:error, reason}
        end
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
  defdelegate logs_only_workspace?(workspace, worker_host), to: Bootstrap

  @doc false
  @spec workspace_readiness(Path.t()) :: :ready | :bootstrap | {:error, term()}
  defdelegate workspace_readiness(workspace), to: Bootstrap

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
  defdelegate workspace_ready_marker_path(workspace), to: Bootstrap

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

  @doc """
  Deletes `workspace` and provisions it again. The only public way to do so:
  the uncommitted work in it is saved first, and a dirty workspace whose work
  cannot be saved is kept (#2743). A remote checkout cannot be saved on this
  daemon, so it is recreated only after an operator authorized the discard
  (`Aiur.Workspace.WipPreservation.authorize_discard/1`).
  """
  @spec recreate(Path.t(), worker_host(), String.t() | nil, String.t(), String.t()) :: :ok | {:error, term()}
  def recreate(workspace, nil, pr_head_ref, branch_name, ticket) when is_binary(branch_name) and is_binary(ticket) do
    WipPreservation.guard_destroy(workspace, ticket, "recreate the stale workspace", fn ->
      Bootstrap.force_recreate_workspace(workspace, branch_name, pr_head_ref)
    end)
  end

  def recreate(workspace, worker_host, _pr_head_ref, _branch_name, ticket) when is_binary(worker_host) and is_binary(ticket) do
    leaf = Path.basename(workspace)

    if WipPreservation.discard_authorized?(leaf) do
      with :ok <- recreate_remote(workspace, worker_host) do
        WipPreservation.emit_discarded_alert(ticket, "#{worker_host}:#{workspace}", :remote_worker_unsupported)
        WipPreservation.consume_discard(leaf)
        WipPreservation.clear_hold(leaf)
      end
    else
      # The exit-65 refusal that leads here already proves the checkout is
      # dirty, and its state cannot be saved to this daemon's state dir.
      WipPreservation.refuse(workspace, ticket, "recreate the stale workspace on #{worker_host}", :remote_worker_unsupported)
    end
  end

  defp recreate_remote(workspace, worker_host) do
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
      {:ok, {_output, 75}} -> DirtyGuard.refuse(workspace, :dirty)
      {:ok, {_output, 76}} -> DirtyGuard.refuse(workspace, :git_status_failed)
      {:ok, {output, status}} -> {:error, {:workspace_prepare_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec cold_fallback_workspace(Path.t(), (-> term())) :: {:ok, Path.t(), true} | {:error, term()}
  def cold_fallback_workspace(workspace, before_recheck \\ fn -> :ok end),
    do: Bootstrap.cold_fallback_workspace(workspace, before_recheck)

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
