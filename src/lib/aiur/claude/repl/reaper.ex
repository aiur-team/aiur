defmodule Aiur.Claude.Repl.Reaper do
  @moduledoc """
  Single source of truth for the owner-pid-encoded window-name scheme, teardown,
  and pane liveness.

  REPL panes live in their own tmux window named `aiur-repl-<beam_os_pid>-<n>`.
  Embedding the owning BEAM's os pid lets the boot reaper kill only panes
  whose owner is dead (never a side-by-side aiur instance's live panes) and
  lets the shutdown sweep kill only this instance's own panes.
  """

  require Logger

  alias Aiur.Claude.RemoteControl
  alias Aiur.Tmux

  # REPL panes live in their own tmux window named `aiur-repl-<beam_os_pid>-<n>`.
  # Embedding the owning BEAM's os pid lets the boot reaper kill only panes
  # whose owner is dead (never a side-by-side aiur instance's live panes) and
  # lets the shutdown sweep kill only this instance's own panes.
  @repl_window_prefix "aiur-repl-"

  @doc """
  Stop the REPL session, prove its pane and whole process group are gone, then
  unregister its reaper keys and emit teardown telemetry.
  """
  @spec stop_session(map()) :: :ok | {:ok, :cleanup_proven} | {:error, {:repl_cleanup_failed, term()}}
  def stop_session(session), do: stop_session(session, [])

  @doc false
  @spec stop_session(map(), keyword()) :: :ok | {:ok, :cleanup_proven} | {:error, {:repl_cleanup_failed, term()}}
  def stop_session(%{tmux: tmux, pane_id: pane_id} = session, opts) do
    os_pid = Map.get(session, :os_pid)
    process_group_id = Map.get(session, :process_group_id)
    process_group_identity = Map.get(session, :process_group_identity, :unknown)
    pane_pid = Tmux.pane_pid(tmux, pane_id)
    pane_proven? = pane_pid == {:ok, os_pid}
    group_alive_fun = Keyword.get(opts, :group_alive_fun, &RemoteControl.process_group_alive?/1)
    group_cleanup_fun = Keyword.get(opts, :group_cleanup_fun, &cleanup_process_group/3)

    group_result =
      cleanup_process_group(
        process_group_id,
        process_group_identity,
        pane_proven?,
        group_alive_fun,
        group_cleanup_fun
      )

    kill_result = Tmux.kill_pane(tmux, pane_id)
    RemoteControl.graceful_kill_tree(os_pid)

    pane_gone? = not match?({:ok, _}, Tmux.pane_pid(tmux, pane_id))
    pid_gone? = os_pid_gone?(os_pid)
    group_gone? = not safely_group_alive?(group_alive_fun, process_group_id)

    result = cleanup_result(group_result, kill_result, pane_gone?, pid_gone?, group_gone?)

    if result == {:ok, :cleanup_proven} do
      Aiur.ProcessReaper.unregister({:pane, pane_id})
      Aiur.ProcessReaper.unregister({:os_pid, os_pid})
    end

    Aiur.Perf.event(:repl_agent_teardown,
      workspace: Map.get(session, :workspace),
      pane_id: pane_id,
      os_pid: os_pid,
      process_group_id: process_group_id,
      pane_gone: pane_gone?,
      pid_gone: pid_gone?,
      group_gone: group_gone?
    )

    result
  end

  def stop_session(_session, _opts), do: :ok

  @doc """
  Kill orphaned REPL panes left by a crashed or hard-killed aiur instance.

  REPL window names embed the owning BEAM's os pid; this kills only panes
  whose owner pid is no longer alive, so a side-by-side aiur instance's live
  panes are never touched. Called at boot alongside
  `Aiur.Claude.RemoteControl.reap_orphaned_servers/0`.
  """
  @spec reap_orphaned_panes(GenServer.server()) :: :ok
  def reap_orphaned_panes(tmux \\ Tmux) do
    sweep_repl_panes(tmux, fn owner_pid -> not os_pid_alive?(owner_pid) end)
  end

  @doc """
  Kill this instance's own REPL panes on graceful shutdown.

  The supervisor brutally kills the runner tasks, skipping their `after
  stop_session` cleanup, so without this sweep a graceful shutdown leaks
  every live REPL pane + `claude` process. Matches only windows owned by
  this BEAM's os pid so a side-by-side aiur instance is never touched.
  """
  @spec sweep_own_panes(GenServer.server()) :: :ok
  def sweep_own_panes(tmux \\ Tmux) do
    self_pid = beam_os_pid()
    sweep_repl_panes(tmux, fn owner_pid -> owner_pid == self_pid end)
  end

  @doc "Generate the default REPL window name embedding this BEAM's os pid."
  @spec default_repl_name() :: String.t()
  def default_repl_name,
    do: "#{@repl_window_prefix}#{beam_os_pid()}-#{System.unique_integer([:positive])}"

  @doc "Return true if the pane is still alive."
  @spec pane_alive?(map()) :: boolean()
  def pane_alive?(%{tmux: tmux, pane_id: pane_id}) do
    match?({:ok, _}, Tmux.pane_pid(tmux, pane_id))
  end

  defp sweep_repl_panes(tmux, owner_match?) do
    case Tmux.list_windows(tmux) do
      {:ok, windows} ->
        windows
        |> Enum.filter(fn {name, _pane} -> String.starts_with?(name, @repl_window_prefix) end)
        |> Enum.each(fn {name, pane_id} ->
          maybe_kill_repl_pane(tmux, name, pane_id, owner_match?)
        end)

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_kill_repl_pane(tmux, name, pane_id, owner_match?) do
    with {:ok, owner_pid} <- parse_owner_pid(name),
         true <- owner_match?.(owner_pid) do
      kill_orphan_pane(tmux, pane_id)
    else
      _ -> :ok
    end
  end

  defp kill_orphan_pane(tmux, pane_id) do
    os_pid =
      case Tmux.pane_pid(tmux, pane_id) do
        {:ok, pid} -> pid
        _ -> nil
      end

    Tmux.kill_pane(tmux, pane_id)
    RemoteControl.graceful_kill_tree(os_pid)
    :ok
  end

  defp beam_os_pid, do: List.to_string(:os.getpid())

  # "aiur-repl-<owner_pid>-<n>" -> {:ok, "<owner_pid>"}; anything else :error.
  defp parse_owner_pid(window_name) do
    case Regex.run(~r/^aiur-repl-(\d+)-\d+/, window_name) do
      [_, owner_pid] -> {:ok, owner_pid}
      _ -> :error
    end
  end

  defp os_pid_alive?(pid) when is_binary(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  rescue
    _ -> true
  end

  defp os_pid_gone?(nil), do: true

  defp os_pid_gone?(pid) when is_integer(pid) do
    not match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp cleanup_process_group(process_group_id, identity, pane_proven?, group_alive_fun, cleanup_fun)
       when is_integer(process_group_id) and process_group_id > 0 do
    if safely_group_alive?(group_alive_fun, process_group_id) do
      cleanup_fun.(process_group_id, identity, pane_proven?)
    else
      {:ok, :gone}
    end
  rescue
    _ -> {:error, :group_cleanup_failed}
  end

  defp cleanup_process_group(_process_group_id, _identity, _pane_proven?, _group_alive_fun, _cleanup_fun),
    do: {:error, :containment_unavailable}

  defp cleanup_process_group(process_group_id, _identity, true),
    do: RemoteControl.graceful_kill_process_group(process_group_id)

  defp cleanup_process_group(process_group_id, identity, false),
    do: RemoteControl.reap_process_group(process_group_id, identity)

  defp safely_group_alive?(group_alive_fun, process_group_id) do
    group_alive_fun.(process_group_id)
  rescue
    _ -> true
  end

  # The post-cleanup observations are the authority. A signal helper can report
  # an error after the target exits concurrently; retaining the workspace in
  # that case would turn a proven cleanup into a permanent false positive.
  defp cleanup_result(_group_result, _kill_result, true, true, true),
    do: {:ok, :cleanup_proven}

  defp cleanup_result(_group_result, _kill_result, _pane_gone?, _pid_gone?, false),
    do: {:error, {:repl_cleanup_failed, :process_group_still_alive}}

  defp cleanup_result(_group_result, _kill_result, false, _pid_gone?, _group_gone?),
    do: {:error, {:repl_cleanup_failed, :pane_still_alive}}

  defp cleanup_result(_group_result, _kill_result, _pane_gone?, false, _group_gone?),
    do: {:error, {:repl_cleanup_failed, :provider_still_alive}}

  defp cleanup_result({:error, reason}, _kill_result, _pane_gone?, _pid_gone?, _group_gone?),
    do: {:error, {:repl_cleanup_failed, reason}}
end
