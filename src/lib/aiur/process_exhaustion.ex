defmodule Aiur.ProcessExhaustion do
  @moduledoc """
  `System.cmd/3` for host probes that must survive a host out of processes.

  When the host cannot fork, `open_port` raises `:eagain` (or `:enomem`) in the
  caller. On 2026-10-10 that caller was `Aiur.Orchestrator`, tearing an agent
  down through a `pgrep` probe while a runaway wrapper chain held 38k
  processes; the orchestrator crashed and the fleet dropped to zero (#4205).
  A probe that cannot run is skipped instead: `cmd/3` returns
  `{:error, reason}` and raises the `system.host.process_exhaustion` alert.
  """

  require Logger

  @alert "system.host.process_exhaustion"
  @alert_interval_ms 60_000
  @reasons [:eagain, :enomem]

  @type result :: {Collectable.t(), non_neg_integer()} | {:error, :eagain | :enomem}

  @spec cmd(binary(), [binary()], keyword()) :: result()
  def cmd(command, args, opts \\ []) do
    seam(:cmd_fun, &System.cmd/3).(command, args, opts)
  rescue
    error in ErlangError ->
      case error.original do
        reason when reason in @reasons ->
          report(command, reason)
          {:error, reason}

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  defp seam(key, default), do: :aiur |> Application.get_env(:process_exhaustion, []) |> Keyword.get(key, default)

  # Every probe fails at once under exhaustion; one alert a minute per calling
  # process says so without a storm.
  defp report(command, reason) do
    now = System.monotonic_time(:millisecond)
    last = Process.get({__MODULE__, :alerted_at})

    if is_nil(last) or now - last >= @alert_interval_ms do
      Process.put({__MODULE__, :alerted_at}, now)
      message = "Host could not spawn #{Path.basename(command)} (#{reason}); the probe was skipped"
      Logger.error("process_exhaustion command=#{command} reason=#{reason}")

      seam(:emit_fun, &Aiur.Alerts.emit_system/2).(@alert,
        message: message,
        reason:
          message <>
            ". The host is out of processes or memory, so process probes and agent teardown are degraded. " <>
            "Look for a runaway process group (`ps -eo pgid=,comm= | sort | uniq -c | sort -n | tail`) and clear it with `kill -9 -- -<pgid>`.",
        needs_attention: true,
        severity: "critical"
      )
    end

    :ok
  rescue
    # Alerting can itself need a process (sounds, notifiers) and must not turn a skipped probe back into a crash.
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
