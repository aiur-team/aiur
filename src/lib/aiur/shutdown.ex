defmodule Aiur.Shutdown do
  @moduledoc """
  Centralized shutdown chokepoint. Runs cleanup before the supervisor
  stops, so opencode sessions Aiur created during this run are deleted
  while `SessionWriterRegistry` is still alive to enumerate them.

  Sequence:
    1. `SessionWriterRegistry.delete_all/1` — walks the registry, calls
       `ApiClient.delete_session/2` per entry, then terminates each writer.
    2. `Supervisor.stop(Aiur.Supervisor, :normal, 5_000)` — orderly OTP
       shutdown. `HiddenWindow.terminate/2` and `Slot.terminate/2`
       close their resources here.
    3. `System.halt(code)`.

  `cleanup/1` is the idempotent prefix used both here and by
  `Aiur.Application.stop/1` (the SIGTERM path where OTP shuts down
  before our chokepoint).

  Crash paths NOT covered by this module: `kill -9`, BEAM panic, OOM.
  Recovery for those is the boot-time GC in `Aiur.Opencode.SessionGC`.
  """

  require Logger

  alias Aiur.Claude.{RemoteControl, ReplAgent}
  alias Aiur.Config
  alias Aiur.Opencode.SessionWriterRegistry

  @default_cleanup_timeout_ms 5_000
  @default_supervisor_stop_timeout_ms 5_000
  @default_tmp_artifact_max_age_ms :timer.hours(6)
  @tmp_artifact_prefixes ["aiur-"]
  @tmp_artifact_names MapSet.new(["aiur-debug", "aiur-rc", "aiur-claude-hooks"])

  @doc """
  Run cleanup (idempotent) without halting. Called by `Aiur.Application.stop/1`.
  """
  @spec cleanup(non_neg_integer()) :: :ok
  def cleanup(timeout_ms \\ @default_cleanup_timeout_ms) do
    # Kind-ordered: agent trees/panes die first (so nothing writes during
    # session deletion), serves die last (delete_all needs them alive for
    # its HTTP deletes). drain: true — anything registered after this sweep
    # is shutdown-orphaned and killed on arrival.
    safely(fn -> Aiur.ProcessReaper.reap([:agent], drain: true) end, "reap_agents")
    safely(fn -> SessionWriterRegistry.delete_all(timeout_ms) end, "delete_all")
    safely(fn -> Aiur.ProcessReaper.reap([:serve], drain: true) end, "reap_serves")
    safely(fn -> ReplAgent.sweep_own_panes() end, "sweep_repl_panes")
    safely(fn -> reap_workspace_agents() end, "reap_workspace_agents")
    safely(fn -> reap_tmp_artifacts() end, "reap_tmp_artifacts")
    safely(fn -> truncate_session_tempfile() end, "truncate_tempfile")
    :ok
  end

  @doc """
  Reap stale top-level Aiur artifacts from the system temp dir.

  The sweep is intentionally conservative: it only considers Aiur-shaped names
  at temp-root depth, only deletes entries older than the age threshold, and
  only touches files owned by the current uid when uid data is available.
  """
  @spec reap_tmp_artifacts(keyword()) :: %{deleted: non_neg_integer(), skipped: non_neg_integer()}
  def reap_tmp_artifacts(opts \\ []) do
    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    max_age_ms = Keyword.get(opts, :max_age_ms, @default_tmp_artifact_max_age_ms)
    now_ms = Keyword.get(opts, :now_ms, System.os_time(:millisecond))
    owner_uid = Keyword.get(opts, :owner_uid, current_uid())
    protected_paths = protected_tmp_paths(opts)

    with true <- is_binary(tmp_dir),
         true <- is_integer(max_age_ms) and max_age_ms >= 0,
         {:ok, entries} <- File.ls(tmp_dir) do
      Enum.reduce(entries, %{deleted: 0, skipped: 0}, fn entry, acc ->
        path = Path.join(tmp_dir, entry)
        reap_tmp_artifact(entry, path, now_ms, max_age_ms, owner_uid, protected_paths, acc)
      end)
    else
      _ -> %{deleted: 0, skipped: 0}
    end
  end

  # Kill claude/node grandchildren the headless backend reparented to init.
  # Gated on :interactive_cli so test-suite cleanup (which resolves the REAL
  # workspace root) never touches live agents.
  defp reap_workspace_agents do
    if Application.get_env(:aiur, :interactive_cli, false) do
      RemoteControl.reap_workspace_agents(Config.workspace_root())
    end

    :ok
  end

  # On graceful exit the BEAM has already deleted every session via
  # `SessionWriterRegistry.delete_all/1`, so the bash trap's reaper
  # should find an empty file and no-op. Truncating (not deleting) lets
  # the trap's `[ -s "$file" ]` check correctly see "nothing to do" while
  # keeping the file in place for any in-flight `File.write` from a
  # late-spawning writer (defensive).
  defp truncate_session_tempfile do
    case System.get_env("AIUR_SESSION_TMPFILE") do
      path when is_binary(path) and path != "" ->
        _ = File.write(path, "")
        :ok

      _ ->
        :ok
    end
  end

  defp protected_tmp_paths(opts) do
    opts
    |> Keyword.get(:protected_paths, [System.get_env("AIUR_SESSION_TMPFILE"), System.get_env("AIUR_LOGS_ROOT")])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> MapSet.new()
  end

  defp tmp_artifact?(name) do
    name in @tmp_artifact_names or Enum.any?(@tmp_artifact_prefixes, &String.starts_with?(name, &1))
  end

  defp reap_tmp_artifact(entry, path, now_ms, max_age_ms, owner_uid, protected_paths, acc) do
    if tmp_artifact?(entry) and stale_tmp_artifact?(path, now_ms, max_age_ms, owner_uid, protected_paths) do
      delete_tmp_artifact(path, acc)
    else
      acc
    end
  end

  defp delete_tmp_artifact(path, acc) do
    case File.rm_rf(path) do
      {:ok, [_ | _]} -> %{acc | deleted: acc.deleted + 1}
      _ -> %{acc | skipped: acc.skipped + 1}
    end
  end

  defp stale_tmp_artifact?(path, now_ms, max_age_ms, owner_uid, protected_paths) do
    expanded = Path.expand(path)

    if MapSet.member?(protected_paths, expanded) do
      false
    else
      stale_unprotected_tmp_artifact?(path, now_ms, max_age_ms, owner_uid)
    end
  end

  defp stale_unprotected_tmp_artifact?(path, now_ms, max_age_ms, owner_uid) do
    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        owner_matches?(stat.uid, owner_uid) and now_ms - stat.mtime * 1_000 >= max_age_ms

      _ ->
        false
    end
  end

  defp owner_matches?(_uid, nil), do: true
  defp owner_matches?(uid, owner_uid), do: uid == owner_uid

  defp current_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {uid, 0} ->
        uid
        |> String.trim()
        |> Integer.parse()
        |> case do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Cleanup, stop the top-level supervisor, then `System.halt(code)`.

  Replaces direct `System.halt` calls in `Aiur.AgentList.App.quit/1`
  and `Aiur.CLI.wait_for_shutdown/0`.
  """
  @spec shutdown() :: no_return()
  @spec shutdown(non_neg_integer()) :: no_return()
  @spec shutdown(non_neg_integer(), keyword()) :: no_return()
  def shutdown(code \\ 0, opts \\ []) do
    cleanup_timeout = Keyword.get(opts, :cleanup_timeout, @default_cleanup_timeout_ms)
    supervisor_timeout = Keyword.get(opts, :supervisor_timeout, @default_supervisor_stop_timeout_ms)

    cleanup(cleanup_timeout)

    safely(
      fn ->
        if Process.whereis(Aiur.Supervisor) do
          Supervisor.stop(Aiur.Supervisor, :normal, supervisor_timeout)
        end
      end,
      "supervisor_stop"
    )

    System.halt(code)
  end

  defp safely(fun, label) do
    fun.()
  catch
    kind, reason ->
      Logger.warning("aiur_shutdown phase=#{label} caught=#{inspect({kind, reason})}")
  end
end
