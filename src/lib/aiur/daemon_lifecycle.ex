defmodule Aiur.DaemonLifecycle do
  @moduledoc """
  Records daemon start and stop in the durable control-lifecycle journal
  (`<log-root>/<repo>.control-lifecycle.json`).

  A second instance or a crash leaves no trace in the running process table, so
  post-incident review has to guess who booted and why the first instance
  exited. Every boot records a `:start` event naming the invoking process (OS
  pid, parent pid + parent comm, hostname, run id, wall-clock) and every
  orderly stop records a `:stop` event. Two instances sharing a host therefore
  both appear in the journal, and an empty journal after an incident is itself
  the signal that the daemon was not started through the normal path.

  The journal lives in the same file as the control-request projection
  (`Aiur.Orchestrator.ControlLifecycleStore`), so it survives daemon restarts
  and is bounded by `ControlLifecycle`'s daemon-event limit.

  All entry points are best-effort: a journal that cannot be read or written
  must never crash boot or block shutdown.
  """

  require Logger

  alias Aiur.Boot
  alias Aiur.Orchestrator.{ControlLifecycle, ControlLifecycleStore}

  @doc """
  Records a daemon `:start` for the current BEAM. Idempotent per run — a
  re-marked boot within the same VM does not append a second start.
  """
  @spec record_start(keyword()) :: :ok
  def record_start(opts \\ []) do
    record(:start, opts)
  end

  @doc """
  Records a daemon `:stop` for the current BEAM. Idempotent per run, so the
  `prep_stop` and `stop` shutdown paths cannot double-record one stop.
  """
  @spec record_stop(keyword()) :: :ok
  def record_stop(opts \\ []) do
    record(:stop, opts)
  end

  @doc """
  Returns the daemon lifecycle events currently persisted in the journal,
  oldest first. Empty when the journal is unreadable or absent.
  """
  @spec daemon_events() :: [ControlLifecycle.daemon_event()]
  def daemon_events do
    ControlLifecycleStore.load()
    |> ControlLifecycle.daemon_events()
  rescue
    _ -> []
  end

  @doc """
  Resolves the invoking process's identity for a journal entry.

  Public so tests can assert the recorded fields without booting a second
  BEAM. `run_id` comes from `Aiur.Boot`; `os_pid` from the VM; parent pid and
  parent comm from `/proc` when available (best-effort, nil elsewhere). `at`
  is the wall-clock timestamp for the event, defaulting to now.
  """
  @spec process_identity(keyword()) :: map()
  def process_identity(opts \\ []) do
    ppid = Keyword.get_lazy(opts, :ppid, &parent_pid/0)

    %{
      run_id: Keyword.get_lazy(opts, :run_id, &Boot.run_id/0),
      os_pid: Keyword.get_lazy(opts, :os_pid, &System.pid/0),
      ppid: ppid,
      ppid_comm: Keyword.get_lazy(opts, :ppid_comm, fn -> parent_comm(ppid) end),
      hostname: Keyword.get_lazy(opts, :hostname, &hostname/0),
      at: Keyword.get_lazy(opts, :at, &DateTime.utc_now/0)
    }
  end

  defp record(kind, opts) do
    identity = process_identity(opts)
    :ok = ControlLifecycleStore.update(&ControlLifecycle.record_daemon_event(&1, kind, identity))
    :ok
  rescue
    error ->
      Logger.warning("aiur_daemon_lifecycle phase=#{kind} error=#{inspect(error)}")
      :ok
  end

  # `:inet.gethostname/0` is documented "never fails" and typed to return
  # only `{:ok, hostname}`, so there is no error branch to handle here.
  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end

  defp parent_pid do
    case File.read("/proc/self/status") do
      {:ok, contents} ->
        case Regex.run(~r/^PPid:\s+(\d+)/m, contents) do
          [_, pid] -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parent_comm(pid) when is_binary(pid) do
    case File.read("/proc/#{pid}/comm") do
      {:ok, comm} -> String.trim(comm)
      _ -> nil
    end
  end

  defp parent_comm(_pid), do: nil
end
