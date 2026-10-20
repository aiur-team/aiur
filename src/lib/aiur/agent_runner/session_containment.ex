defmodule Aiur.AgentRunner.SessionContainment do
  @moduledoc false
  alias Aiur.AgentRunner.SessionCleanup
  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.ProcessTree
  alias Aiur.Workspace.Ownership
  import Aiur.AgentRunner.SessionStartup, only: [record_session_start_failure: 3]
  import Aiur.AgentRunner.SessionIdentity
  @type worker_host :: String.t() | nil

  # The live session's OS-level runtime (REPL pane + agent os pid, or the
  # headless wrapper's bash pid) is owned by this runner task. An
  # abort/shutdown brutally kills the task, skipping the `after
  # stop_session` cleanup, so report it to the orchestrator's running
  # entry for abort cleanup. Report the registry-declared `runtime_report`
  # capability (`Aiur.CodingAgent.runtime_report/1`).
  @doc false
  @spec report_repl_session(term(), term(), term()) :: term()
  def report_repl_session(recipient, %Issue{id: issue_id}, session)
      when is_binary(issue_id) and is_pid(recipient) do
    case session_runtime_info(session) do
      nil ->
        :ok

      info ->
        send(recipient, {:repl_session_runtime, issue_id, info})
        :ok
    end
  end

  def report_repl_session(_recipient, _issue, _session), do: :ok

  @doc false
  @spec report_pause_containment(term(), term(), term()) :: term()
  def report_pause_containment(recipient, %Issue{id: issue_id}, %{containment: containment, metadata: metadata})
      when is_pid(recipient) and is_binary(issue_id) and is_map(containment) do
    send(recipient, {
      :pause_containment_runtime,
      issue_id,
      %{generation: containment[:generation], process_group_id: metadata[:agent_process_group_id]}
    })

    :ok
  end

  def report_pause_containment(_recipient, _issue, _session), do: :ok

  defp session_runtime_info(session) do
    case CodingAgent.runtime_report(session_backend!(session)) do
      :repl_pane ->
        %{
          pane_id: Map.get(session, :pane_id),
          tmux_socket: Map.get(session, :tmux_socket),
          os_pid: Map.get(session, :os_pid),
          session_url: Map.get(session, :session_url)
        }

      :headless_wrapper ->
        case headless_os_pid(session) do
          nil -> nil
          pid -> %{headless_os_pid: pid, headless_process_group_id: process_group_id(session)}
        end

      nil ->
        nil
    end
  end

  defp headless_os_pid(%{metadata: metadata}) when is_map(metadata) do
    pid = metadata[:provider_pid] || metadata[:claude_app_server_pid]

    case pid do
      pid when is_binary(pid) ->
        case Integer.parse(pid) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp headless_os_pid(_session), do: nil

  defp process_group_id(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :agent_process_group_id) do
      process_group_id when is_integer(process_group_id) and process_group_id > 0 ->
        process_group_id

      process_group_id when is_binary(process_group_id) ->
        case Integer.parse(process_group_id) do
          {value, ""} when value > 0 -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp process_group_id(_session), do: nil

  @doc false
  @spec workspace_process_group_tracker(term()) :: term()
  def workspace_process_group_tracker(nil), do: fn _process_group_id -> :ok end

  def workspace_process_group_tracker(ownership) do
    fn process_group_id -> Ownership.track_process_group(ownership, process_group_id) end
  end

  @doc false
  @spec workspace_provider_tracker(term()) :: term()
  def workspace_provider_tracker(nil), do: fn _provider -> :ok end

  def workspace_provider_tracker(ownership) do
    fn provider -> Ownership.track_provider(ownership, provider) end
  end

  @doc false
  @spec workspace_cleanup_tracker(term()) :: term()
  def workspace_cleanup_tracker(nil), do: fn _outcome -> :ok end

  def workspace_cleanup_tracker(ownership) do
    fn
      :succeeded -> Ownership.mark_provider_cleanup_succeeded(ownership)
      _outcome -> Ownership.mark_provider_cleanup_unknown(ownership)
    end
  end

  @doc false
  @spec with_expected_provider(term(), term(), term(), term(), term()) :: term()
  def with_expected_provider(nil, _scope, start, _issue, _session_context), do: start.(nil)

  def with_expected_provider(ownership, scope, start, issue, session_context) do
    case Ownership.expect_provider(ownership, scope) do
      :ok ->
        start.(ownership)

      {:error, reason} = error ->
        record_session_start_failure(issue, session_context, reason)
        error
    end
  end

  @doc false
  @spec cancel_pre_spawn_provider_expectation(term(), term()) :: term()
  def cancel_pre_spawn_provider_expectation(ownership, reason) do
    if pre_spawn_start_error?(reason), do: Ownership.cancel_provider_expectation(ownership)
    :ok
  end

  @doc false
  @spec mark_provider_cleanup_unknown(term(), term()) :: term()
  def mark_provider_cleanup_unknown(ownership, {:repl_cleanup_failed, _reason}),
    do: Ownership.mark_provider_cleanup_unknown(ownership)

  def mark_provider_cleanup_unknown(_ownership, _reason), do: :ok

  # These are the only errors whose producers prove that no backend process
  # exists. Keep this deliberately narrow: any error after a port or pane may
  # have escaped containment discovery, so its expectation must stay
  # fail-closed for the guardian to reap or prove it gone.
  defp pre_spawn_start_error?(reason)
       when reason in [
              :bash_not_found,
              :no_tmux,
              :no_tmux_executable,
              :remote_control_requires_dashboard,
              :receiver_unavailable,
              :missing_tracker_identity,
              :remote_worker_unsupported,
              :invalid_correlation,
              :capability_unavailable
            ],
       do: true

  # Codex and Claude reject their workspace root before invoking their spawn
  # adapters. The local/root and remote-path variants intentionally carry
  # different arities, so both belong to the authoritative no-spawn set.
  defp pre_spawn_start_error?({:invalid_workspace_cwd, _, _}), do: true
  defp pre_spawn_start_error?({:invalid_workspace_cwd, _, _, _}), do: true
  defp pre_spawn_start_error?(_reason), do: false

  @doc false
  @spec stop_session_with_ownership(map(), Ownership.lease() | nil, (map() -> term())) :: term()
  def stop_session_with_ownership(session, ownership, stop_fun \\ &CodingAgent.stop_session/1)
      when is_map(session) and is_function(stop_fun, 1) do
    SessionCleanup.stop(session, ownership, stop_fun)
  end

  # A missing local process group is expected for remote workers, headless
  # adapters, and an occasional `ps` lookup miss. The provider itself is still
  # registered, so only send a process-group update when it is meaningful.
  @doc false
  @spec track_session_containment(Ownership.lease() | nil, map(), worker_host()) ::
          :ok | {:error, :workspace_ownership_lost}
  def track_session_containment(nil, _session, _worker_host), do: :ok

  def track_session_containment(ownership, session, worker_host) do
    with :ok <- track_session_process_group(ownership, process_group_id(session)) do
      Ownership.track_provider(ownership, session_provider(session, worker_host))
    end
  end

  defp track_session_process_group(_ownership, nil), do: :ok

  defp track_session_process_group(ownership, process_group_id),
    do: Ownership.track_process_group(ownership, process_group_id)

  defp session_provider(session, worker_host) do
    metadata = Map.get(session, :metadata, %{})

    %{}
    |> maybe_put_provider_pid(metadata[:provider_pid] || metadata[:codex_app_server_pid] || metadata[:claude_app_server_pid])
    |> maybe_put_provider_pid(Map.get(session, :os_pid))
    |> maybe_put_provider_group(process_group_id(session))
    |> maybe_put_remote_provider(worker_host)
    |> maybe_put_provider_processes(worker_host)
    |> maybe_put_in_process_provider()
  end

  # An in-process session (an OpenAI-compatible HTTP agent) has no OS process,
  # process group, or remote host to contain. Mark it explicitly so the
  # workspace guardian accepts it: such a session is a child of the runner and
  # dies with it, so there is nothing to reap on owner death. Without this, the
  # guardian's `valid_provider?` rejects the empty provider and every dispatch
  # fails with `:workspace_ownership_lost` before the first turn. Only mark
  # providers that carry no OS identity; a session that reports a root pid,
  # process group, remote host, or descendants is reaped normally.
  defp maybe_put_in_process_provider(%{} = provider) when map_size(provider) == 0,
    do: Map.put(provider, :in_process, true)

  defp maybe_put_in_process_provider(provider), do: provider

  defp maybe_put_provider_pid(provider, pid) when is_integer(pid) and pid > 0,
    do: Map.put(provider, :root_pid, pid)

  defp maybe_put_provider_pid(provider, pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {value, ""} when value > 0 -> Map.put(provider, :root_pid, value)
      _ -> provider
    end
  end

  defp maybe_put_provider_pid(provider, _pid), do: provider
  defp maybe_put_provider_group(provider, pid) when is_integer(pid) and pid > 0, do: Map.put(provider, :process_group_id, pid)
  defp maybe_put_provider_group(provider, _pid), do: provider
  defp maybe_put_remote_provider(provider, worker_host) when is_binary(worker_host), do: Map.put(provider, :remote, true)
  defp maybe_put_remote_provider(provider, _worker_host), do: provider

  defp maybe_put_provider_processes(provider, worker_host) when is_binary(worker_host), do: provider

  defp maybe_put_provider_processes(%{root_pid: root_pid} = provider, _worker_host),
    do: Map.put(provider, :descendant_pids, ProcessTree.process_tree(root_pid))

  defp maybe_put_provider_processes(provider, _worker_host), do: provider
end
