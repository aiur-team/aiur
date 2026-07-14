defmodule Aiur.Workspace.Provisioner do
  @moduledoc """
  Provisions local and remote workspaces, including prewarm materialization and
  stale workspace recreation.
  """

  require Logger
  alias Aiur.{Config, RepoBase, TicketBranch, Tracker}
  alias Aiur.RunTelemetry.Lifecycle
  alias Aiur.Workspace.{Checkout, Context, Materialize, Remote}

  @remote_workspace_marker "__AIUR_WORKSPACE__"

  @doc false
  # Install aiur's bundled agent-operating skills (`using-aiur`, `/aiur-agent`)
  # into the freshly populated workspace so the agent can load the skills the
  # per-turn prompt routes it to instead of full-disk-searching (#689). Local
  # Remote workers receive the same embedded files through one idempotent SSH
  # script, so prompt-referenced skills resolve on either execution host.
  @spec maybe_install_agent_skills(Path.t(), String.t() | nil) :: :ok
  def maybe_install_agent_skills(workspace, nil), do: Aiur.AgentSkills.install(workspace)

  def maybe_install_agent_skills(workspace, worker_host) when is_binary(worker_host) do
    maybe_install_agent_skills(workspace, worker_host, &Remote.run_remote_command/3)
  end

  @doc false
  @spec maybe_install_agent_skills(Path.t(), String.t(), (String.t(), String.t(), pos_integer() -> term())) :: :ok
  def maybe_install_agent_skills(workspace, worker_host, runner)
      when is_binary(workspace) and is_binary(worker_host) and is_function(runner, 3) do
    script = Aiur.AgentSkills.remote_install_script(workspace)

    case runner.(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      result ->
        Logger.warning("remote agent skill install failed worker_host=#{worker_host} result=#{inspect(result)}")
        :ok
    end
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

      incomplete_workspace?(workspace) ->
        record_prewarm_point(lifecycle, :incomplete, :rebuild)
        {:ok, workspace, true}

      File.dir?(workspace) ->
        record_prewarm_point(lifecycle, :existing, :skipped)
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_or_materialize(workspace, branch_name, pr_head_ref, lifecycle)

      true ->
        create_or_materialize(workspace, branch_name, pr_head_ref, lifecycle)
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

      incomplete_workspace?(workspace) ->
        {:ok, workspace, true}

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

  # Event logging can create a `logs/` directory before provisioning starts.
  # Empty directories and partial clones are incomplete for the same reason.
  # Other existing non-Git paths retain the long-standing reuse contract: they
  # may have been initialized by a user-provided after_create hook that does
  # not itself create a Git checkout.
  defp incomplete_workspace?(workspace) do
    case File.ls(workspace) do
      {:ok, []} ->
        true

      {:ok, ["logs"]} ->
        true

      {:ok, entries} ->
        ".git" in entries

      {:error, _reason} ->
        true
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
