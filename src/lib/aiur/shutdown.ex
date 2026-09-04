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

  alias Aiur.{AlertLedger, Config}
  alias Aiur.Claude.{RemoteControl, ReplAgent}
  alias Aiur.Fs
  alias Aiur.Opencode.SessionWriterRegistry

  @default_cleanup_timeout_ms 5_000
  @default_supervisor_stop_timeout_ms 5_000

  # Where the last successfully resolved workspace root is parked, so the
  # shutdown phases can reuse it instead of re-deriving config. See
  # `workspace_root/1` for why re-deriving on that path is unsafe.
  @workspace_root_cache {__MODULE__, :workspace_root}

  @doc """
  Run cleanup (idempotent) without halting. Called by `Aiur.Application.stop/1`.
  """
  @spec cleanup(non_neg_integer()) :: :ok
  def cleanup(timeout_ms \\ @default_cleanup_timeout_ms) do
    # `derive: false` — this runs on the shutdown path, where deriving config is
    # a deadlock. See `workspace_root/1`.
    safely(fn -> record_workspace_root(derive: false) end, "record_workspace_root")
    # Durable daemon-lifecycle journal: record the orderly stop before the
    # supervision tree comes down. Idempotent per run, so the `prep_stop` and
    # `stop` paths cannot double-record one stop. Best-effort with a bounded
    # lock deadline — a journal write must never block shutdown.
    safely(fn -> Aiur.DaemonLifecycle.record_stop() end, "record_daemon_stop")

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

  @doc """
  Record the canonical project-scoped alert ledger for the launcher watchdog.

  The watchdog outlives the BEAM and cannot safely reconstruct tracker-derived
  project identity after a crash, so the running application hands off the
  already-resolved path atomically.
  """
  @spec record_alert_ledger_path() :: :ok
  def record_alert_ledger_path do
    record_path_handoff("AIUR_ALERT_LEDGER_PATH_FILE", AlertLedger.path(), "record_alert_ledger_path")
  catch
    kind, reason ->
      Logger.warning("aiur_shutdown phase=record_alert_ledger_path caught=#{inspect({kind, reason})}")
      :ok
  end

  @doc """
  Record the configured workspace root for the launcher-side shutdown backstop.

  The bash engine cannot safely re-derive full Aiur config after the BEAM exits,
  so the running application writes the resolved root into a per-run tempfile.
  The write is atomic (temp file + rename) so a BEAM killed mid-write can never
  hand the launcher a truncated root that still passes its shallow-root guard.
  Best-effort: shutdown must continue if this file is absent or unwritable.

  `derive: false` (what `cleanup/1` passes) forbids re-deriving config to answer
  the question — see `workspace_root/1`.
  """
  @spec record_workspace_root() :: :ok
  @spec record_workspace_root(keyword()) :: :ok
  def record_workspace_root(opts \\ []) do
    case workspace_root(Keyword.get(opts, :derive, true)) do
      {:ok, root} ->
        record_path_handoff("AIUR_WORKSPACE_ROOT_FILE", root, "record_workspace_root")

      :unavailable ->
        Logger.debug("aiur_shutdown phase=record_workspace_root skipped=config_unavailable")
        :ok
    end
  catch
    kind, reason ->
      Logger.warning("aiur_shutdown phase=record_workspace_root caught=#{inspect({kind, reason})}")
      :ok
  end

  # Resolving the workspace root means reading config, and reading config with
  # `Aiur.WorkflowStore` down falls back to parsing the workflow YAML from disk.
  # YamlElixir calls `Application.start(:yamerl)` on *every* read, and that is a
  # `:application_controller` call. Harmless at boot — the controller answers
  # calls while `start/2` runs — but a deadlock on the shutdown path, where the
  # controller is already blocked terminating this very application and the call
  # has no timeout. It never returns, and `:application_controller` stays wedged
  # for the rest of the VM.
  #
  # That is the #2548 cascade: one toppled supervision tree wedged the
  # controller, every later test that touched `Application.put_env/3` or
  # `ensure_all_started/1` then burned its full 60s ExUnit timeout, and the
  # coverage partition blew through its 20-minute bound.
  #
  # So `derive: false` callers get the value parked by the last successful
  # resolution, or nothing at all. Every phase in `cleanup/1` is documented
  # best-effort: skipping one beats deadlocking shutdown.
  defp workspace_root(derive?) do
    if derive? or is_pid(Process.whereis(Aiur.WorkflowStore)) do
      root = Config.workspace_root()
      :persistent_term.put(@workspace_root_cache, root)
      {:ok, root}
    else
      case :persistent_term.get(@workspace_root_cache, :unavailable) do
        root when is_binary(root) -> {:ok, root}
        :unavailable -> :unavailable
      end
    end
  end

  defp record_path_handoff(env_name, value, phase) do
    case System.get_env(env_name) do
      path when is_binary(path) and path != "" ->
        case Fs.atomic_write(path, value) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("aiur_shutdown phase=#{phase} error=#{inspect(reason)}")
        end

        :ok

      _ ->
        :ok
    end
  end

  # Kill the whole agent tree the backends reparented to init — coding agents,
  # opencode clients, and the mix/beam.smp test children they spawn (#453).
  # Gated on a real run (interactive foreground OR a `--bg`/headless node) so
  # test-suite cleanup — which resolves the REAL workspace root but sets neither
  # flag — never touches live agents. A headless `--bg` node still uses the
  # reparenting backend, so it must reap here too.
  defp reap_workspace_agents do
    if Application.get_env(:aiur, :interactive_cli, false) or
         Application.get_env(:aiur, :headless, false) do
      # Same `:application_controller` deadlock hazard as `record_workspace_root/1`
      # — this phase also runs after teardown — so it takes the same guarded root.
      case workspace_root(false) do
        {:ok, root} -> RemoteControl.reap_workspace_agents(root)
        :unavailable -> :ok
      end
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
