defmodule Aiur.Workspace.Provisioner do
  @moduledoc "Workspace provisioning: ensure, create, materialize from prewarm base, recreate stale workspaces, and remote SSH shell provisioning."

  require Logger
  alias Aiur.{Config, RepoBase, TicketBranch, Tracker}
  alias Aiur.Workspace.{Checkout, Context, Materialize, Remote}

  @remote_workspace_marker "__AIUR_WORKSPACE__"

  @doc false
  # Install aiur's bundled agent-operating skills (`using-aiur`, `/aiur-agent`)
  # into the freshly populated workspace so the agent can load the skills the
  # per-turn prompt routes it to instead of full-disk-searching (#689). Local
  # worker only — a remote worker materializes on another host where these local
  # file writes wouldn't land. Idempotent, so reuse + re-dispatch are safe.
  @spec maybe_install_agent_skills(Path.t(), String.t() | nil) :: :ok
  def maybe_install_agent_skills(workspace, nil), do: Aiur.AgentSkills.install(workspace)
  def maybe_install_agent_skills(_workspace, worker_host) when is_binary(worker_host), do: :ok

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
  def ensure_workspace(workspace, nil, pr_head_ref, branch_name) when is_binary(branch_name) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_or_materialize(workspace, branch_name, pr_head_ref)

      true ->
        create_or_materialize(workspace, branch_name, pr_head_ref)
    end
  end

  def ensure_workspace(workspace, worker_host, _pr_head_ref, _branch_name)
      when is_binary(worker_host) do
    ensure_workspace(workspace, worker_host)
  end

  @spec ensure_workspace(Path.t(), worker_host()) ::
          {:ok, Path.t(), boolean() | :materialized} | {:error, term()}
  def ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_or_materialize(workspace, legacy_branch_name(workspace), nil)

      true ->
        create_or_materialize(workspace, legacy_branch_name(workspace), nil)
    end
  end

  def ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        Remote.remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
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
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case Remote.run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
  def recreate(workspace, nil) do
    {:ok, _workspace, _created?} =
      create_or_materialize(workspace, legacy_branch_name(workspace), nil)

    :ok
  end

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
    {:ok, _workspace, _created?} = create_or_materialize(workspace, branch_name, pr_head_ref)
    :ok
  end

  def recreate(workspace, worker_host, _pr_head_ref, _branch_name) when is_binary(worker_host),
    do: recreate(workspace, worker_host)

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  # When pre-warm is enabled and the shared base is ready, materialize the
  # workspace from it (copy-on-write where the filesystem supports it, carrying
  # the warm `_build`/deps) instead of cold-cloning + recompiling. Anything that
  # rules pre-warm out — disabled, base not ready, missing, or a copy failure —
  # falls through to the unchanged cold `create_workspace/1` path.
  defp create_or_materialize(workspace, branch_name, pr_head_ref) do
    with true <- Config.prewarm_enabled?(),
         {:ready, base} when is_binary(base) <- RepoBase.status(),
         true <- File.dir?(base),
         :ok <- Materialize.materialize_from_base(base, workspace, branch_name, pr_head_ref) do
      {:ok, workspace, :materialized}
    else
      _ -> create_workspace(workspace)
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
