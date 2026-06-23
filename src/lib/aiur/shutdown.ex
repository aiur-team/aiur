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
    safely(fn -> truncate_session_tempfile() end, "truncate_tempfile")
    :ok
  end

  # Kill the whole agent tree the backends reparented to init — coding agents,
  # opencode clients, and the mix/beam.smp test children they spawn (#453).
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
