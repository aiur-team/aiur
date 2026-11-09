defmodule Aiur.DiskWatchdog do
  @moduledoc """
  Watches free space on the filesystems holding `workspace.root`, the run-log
  root and `~/.aiur`, so a full disk is announced before it crashes the daemon
  (#7880).

  Above `monitoring.disk_alert_percent` used it raises `system.disk.pressure`
  once per episode, naming the filesystem and the largest workspace
  directories. Above `monitoring.disk_stop_dispatch_percent` the dispatcher's
  admission gate holds new dispatch (`dispatch_gate/1`) and `aiur status` says
  why. When usage falls back below the alert line, `system.disk.pressure.resolved`
  fires and dispatch resumes. A failed sample is `:unknown`: it never alerts,
  never holds dispatch, and renders as `unknown`, never as 0%.
  """

  use GenServer

  require Logger

  alias Aiur.{Config, ProcessExhaustion, Signal}

  @topic "system.disk.pressure"
  @interval_ms 60_000
  @status_key {__MODULE__, :status}
  @top 5
  @rank %{ok: 0, warn: 1, stop: 2}

  @type filesystem :: %{device: String.t(), mount: String.t(), used_percent: non_neg_integer(), free_bytes: non_neg_integer()}
  @type level :: :ok | :warn | :stop
  @type status ::
          %{level: level(), worst: filesystem(), filesystems: [filesystem()], alert_percent: number(), stop_percent: number()}
          | :unknown

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  One check. `alerted` is the highest level already alerted in this episode.
  Returns the new alerted level and the classified status.
  """
  @spec check(level(), keyword()) :: {level(), status()}
  def check(alerted, opts \\ []) do
    {alert_percent, stop_percent} = Keyword.get(opts, :thresholds_fun, &thresholds/0).()
    status = classify(Keyword.get(opts, :sample_fun, &sample/0).(), alert_percent, stop_percent)
    alert = Keyword.get(opts, :alert_fun, &Signal.alert/2)
    {next_alerted(alerted, status, alert, opts), status}
  end

  @doc "The last published status, or `nil` before the first sample."
  @spec current() :: status() | nil
  def current, do: :persistent_term.get(@status_key, nil)

  @doc "Admission gate: holds new dispatch only at the stop level; an unknown sample fails open."
  @spec dispatch_gate(status() | nil) :: :dispatch | {:hold, map()}
  def dispatch_gate(status \\ current())

  def dispatch_gate(%{level: :stop, worst: worst, stop_percent: stop_percent}) do
    {:hold, %{signal: :disk, measured: worst.used_percent, threshold: stop_percent, detail: "mount=#{worst.mount} free=#{human(worst.free_bytes)}"}}
  end

  def dispatch_gate(_status), do: :dispatch

  @doc "The `DISK` line of `aiur status`."
  @spec status_line(status() | nil) :: String.t()
  def status_line(status \\ current())
  def status_line(nil), do: "DISK unknown (not sampled yet)"
  def status_line(:unknown), do: "DISK unknown (free-space sample failed)"

  def status_line(%{worst: worst} = status) do
    stopped = if status.level == :stop, do: "; new dispatch stopped", else: ""

    "DISK #{worst.mount} #{worst.used_percent}% used, #{human(worst.free_bytes)} free " <>
      "(alert at #{status.alert_percent}%, dispatch stops at #{status.stop_percent}%)#{stopped}"
  end

  @doc "Parses POSIX `df -Pk` output; no usable row is `:unknown`."
  @spec parse_df(String.t()) :: [filesystem()] | :unknown
  def parse_df(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(&parse_df_row/1)
    |> Enum.uniq_by(& &1.mount)
    |> case do
      [] -> :unknown
      filesystems -> filesystems
    end
  end

  defp parse_df_row(row) do
    with [device, _total, _used, avail, capacity | mount] <- String.split(row),
         {avail_kb, ""} <- Integer.parse(avail),
         {used_percent, "%"} <- Integer.parse(capacity),
         [_ | _] <- mount do
      [%{device: device, mount: Enum.join(mount, " "), used_percent: used_percent, free_bytes: avail_kb * 1024}]
    else
      _ -> []
    end
  end

  @impl true
  def init(opts) do
    send(self(), :check)
    {:ok, %{opts: opts, alerted: :ok}}
  end

  @impl true
  def handle_info(:check, state) do
    Process.send_after(self(), :check, Keyword.get(state.opts, :interval_ms, @interval_ms))
    {:noreply, %{state | alerted: safe_check(state)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A probe or alert failure must not restart this child every tick.
  defp safe_check(state) do
    {alerted, status} = check(state.alerted, state.opts)
    :persistent_term.put(@status_key, status)
    alerted
  rescue
    error ->
      Logger.warning("disk_watchdog check_failed error=#{Exception.message(error)}")
      state.alerted
  catch
    kind, reason ->
      Logger.warning("disk_watchdog check_failed #{kind}=#{inspect(reason)}")
      state.alerted
  end

  defp classify(filesystems, alert_percent, stop_percent) when is_list(filesystems) and filesystems != [] do
    worst = Enum.max_by(filesystems, & &1.used_percent)

    level =
      cond do
        worst.used_percent >= stop_percent -> :stop
        worst.used_percent >= alert_percent -> :warn
        true -> :ok
      end

    %{level: level, worst: worst, filesystems: filesystems, alert_percent: alert_percent, stop_percent: stop_percent}
  end

  defp classify(_sample, _alert_percent, _stop_percent), do: :unknown

  # An unknown sample keeps the episode as it was: no alert, no resolve.
  defp next_alerted(alerted, :unknown, _alert, _opts), do: alerted

  defp next_alerted(alerted, %{level: :ok} = status, alert, _opts) do
    if alerted != :ok,
      do: alert.("#{@topic}.resolved", message: "Disk usage back to #{status.worst.used_percent}% on #{status.worst.mount}", needs_attention: false)

    :ok
  end

  # Stays at the episode's highest level until usage clears, so a value
  # hovering on a threshold does not re-alert every minute.
  defp next_alerted(alerted, %{level: level} = status, alert, opts) do
    if @rank[level] > @rank[alerted] do
      alert.(@topic, pressure_alert(status, Keyword.get(opts, :largest_fun, &largest_workspaces/0).()))
      level
    else
      alerted
    end
  end

  defp pressure_alert(%{worst: worst} = status, largest) do
    action = if status.level == :stop, do: "New dispatch is stopped until usage drops below #{status.stop_percent}%.", else: "Dispatch stops at #{status.stop_percent}%."
    message = "Disk #{worst.mount} (#{worst.device}) is #{worst.used_percent}% used, #{human(worst.free_bytes)} free"
    dirs = if largest == [], do: "unavailable", else: Enum.map_join(largest, ", ", fn {path, bytes} -> "#{path} #{human(bytes)}" end)
    Logger.warning("disk_watchdog pressure mount=#{worst.mount} used_percent=#{worst.used_percent} free_bytes=#{worst.free_bytes}")

    [
      message: message,
      reason: "#{message}. #{action} Largest workspace directories: #{dirs}. Free space before the daemon crashes on a full disk.",
      needs_attention: true,
      severity: if(status.level == :stop, do: "critical", else: "warning")
    ]
  end

  defp sample do
    case ProcessExhaustion.cmd("df", ["-Pk" | Enum.map(watched_paths(), &existing_ancestor/1)], stderr_to_stdout: false) do
      {:error, _reason} -> :unknown
      {output, _exit} -> parse_df(output)
    end
  rescue
    _error -> :unknown
  end

  defp watched_paths do
    [&Config.workspace_root/0, &Config.Paths.log_root_dir/0, fn -> Path.join(System.user_home!(), ".aiur") end]
    |> Enum.flat_map(fn path_fun ->
      try do
        [path_fun.()]
      rescue
        _error -> []
      end
    end)
  end

  defp existing_ancestor(path) do
    path = Path.expand(path)
    if File.exists?(path) or Path.dirname(path) == path, do: path, else: existing_ancestor(Path.dirname(path))
  end

  # ponytail: `du` over a huge workspace root can take minutes; it runs only when an alert fires, in this process.
  defp largest_workspaces do
    root = Path.expand(Config.workspace_root())

    case ProcessExhaustion.cmd("du", ["-k", "-d", "2", root], stderr_to_stdout: false) do
      {:error, _reason} ->
        []

      {output, _exit} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_du_line(&1, root))
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(@top)
    end
  rescue
    _error -> []
  end

  defp parse_du_line(line, root) do
    with [kb, path] <- String.split(line, "\t", parts: 2),
         {kb, ""} <- Integer.parse(kb),
         true <- path != root do
      [{Path.relative_to(path, root), kb * 1024}]
    else
      _ -> []
    end
  end

  defp thresholds do
    monitoring = Config.settings!().monitoring
    {monitoring.disk_alert_percent, monitoring.disk_stop_dispatch_percent}
  rescue
    _error -> {90, 97}
  end

  defp human(bytes) when bytes >= 1_099_511_627_776, do: "#{Float.round(bytes / 1_099_511_627_776, 1)} TiB"
  defp human(bytes) when bytes >= 1_073_741_824, do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
  defp human(bytes), do: "#{div(bytes, 1_048_576)} MiB"
end
