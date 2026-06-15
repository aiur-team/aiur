defmodule Aiur.LauncherWatchdog do
  @moduledoc """
  Self-halt safety net for the detached release BEAM.

  The interactive BEAM runs inside a detached tmux session, so when the
  operator closes their terminal the tmux server keeps the pane — and the
  BEAM — alive. The BEAM's own signal handlers never fire (its controlling
  terminal is the persistent tmux pane, not the operator's window), and if
  the bash trap in `scripts/aiurdev` is bypassed (the wrapper is SIGKILLed,
  or the terminal app tears its process group down hard) nothing tells the
  BEAM to stop. The agents keep working and burning tokens with no UI
  attached.

  This watchdog polls the launcher wrapper's OS pid, passed in via
  `AIUR_LAUNCHER_PID`. That wrapper's lifetime equals the operator's UI
  session: it runs `tmux attach` in the foreground and exits the moment the
  operator detaches or closes the window. When the pid disappears the
  watchdog drives the full `Aiur.Shutdown.shutdown/1` chokepoint so opencode
  sessions are deleted and workspace agents are reaped — the agents actually
  stop.

  Armed only on the interactive CLI path with a launcher pid present; the
  ExUnit suite and headless runs never start it. PID reuse within the poll
  interval could mask a dead launcher, but that only degrades to the prior
  behavior (a missed halt, never a false halt of a live session).
  """

  use GenServer

  require Logger

  # The default on_launcher_gone closure calls Aiur.Shutdown.shutdown/1
  # (no_return by design — it halts the VM), which dialyzer flags as an
  # anonymous function with no local return. Intentional; suppress.
  @dialyzer {:nowarn_function, init: 1}

  @default_interval_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    launcher_pid = Keyword.get(opts, :launcher_pid, System.get_env("AIUR_LAUNCHER_PID"))

    case parse_pid(launcher_pid) do
      {:ok, pid} ->
        interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
        alive_fun = Keyword.get(opts, :alive_fun, &default_alive?/1)
        on_gone = Keyword.get(opts, :on_launcher_gone, fn -> Aiur.Shutdown.shutdown(0) end)
        Logger.info("aiur_watchdog phase=armed launcher_pid=#{pid} interval_ms=#{interval}")
        schedule(interval)
        {:ok, %{pid: pid, interval: interval, alive_fun: alive_fun, on_gone: on_gone}}

      :error ->
        :ignore
    end
  end

  @impl true
  def handle_info(:check, state) do
    if state.alive_fun.(state.pid) do
      schedule(state.interval)
      {:noreply, state}
    else
      Logger.warning("aiur_watchdog phase=launcher_gone launcher_pid=#{state.pid} action=shutdown")
      state.on_gone.()
      {:stop, :normal, state}
    end
  end

  defp schedule(interval), do: Process.send_after(self(), :check, interval)

  defp parse_pid(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_pid(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {pid, ""} when pid > 0 -> {:ok, pid}
      _ -> :error
    end
  end

  defp parse_pid(_), do: :error

  defp default_alive?(pid), do: File.dir?("/proc/#{pid}")
end
