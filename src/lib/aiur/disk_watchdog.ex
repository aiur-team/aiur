defmodule Aiur.DiskWatchdog do
  @moduledoc """
  Watches free space on the filesystems holding `workspace.root`, the run-log
  root and `~/.aiur`, so a full disk is announced before it crashes the daemon
  (#7880).

  Above `monitoring.disk_alert_percent` used it raises `system.disk.pressure`
  once per episode, naming the filesystem and the largest workspace
  directories. At `monitoring.disk_stop_dispatch_percent`, or below
  `monitoring.disk_stop_dispatch_free_gb` free, the dispatcher's admission gate
  holds new dispatch (`dispatch_gate/1`) and `aiur status` says why. The hold
  ends only once usage is 2 points under the stop line and free space is 2% of
  the filesystem above the floor, so a disk hovering on the line does not flip
  dispatch every minute. When usage falls back below the alert line,
  `system.disk.pressure.resolved` fires.

  The status is published before the slow `du` behind the alert runs, and both
  `df` and `du` run under a hard timeout. A failed or timed-out sample is
  `:unknown`, and a sample older than three intervals is stale: neither alerts,
  holds dispatch, or renders as a percentage.
  """

  use GenServer

  require Logger

  alias Aiur.{Config, ProcessExhaustion, Signal}

  @topic "system.disk.pressure"
  @interval_ms 60_000
  @stale_ms 3 * @interval_ms
  @df_timeout_ms 10_000
  @du_timeout_ms 30_000
  @resume_margin_percent 2
  @gib 1_073_741_824
  @top 5
  @rank %{ok: 0, warn: 1, stop: 2}

  @type filesystem :: %{
          device: String.t(),
          mount: String.t(),
          used_percent: non_neg_integer(),
          free_bytes: non_neg_integer(),
          size_bytes: non_neg_integer()
        }
  @type level :: :ok | :warn | :stop
  @type status ::
          %{
            level: level(),
            worst: filesystem(),
            filesystems: [filesystem()],
            alert_percent: number(),
            stop_percent: number(),
            floor_bytes: non_neg_integer(),
            sampled_at_ms: integer()
          }
          | :unknown
          | {:stale, non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  One check. `alerted` is the highest level already alerted in this episode;
  `held: true` means the previous status held dispatch. The status is published
  before the alert's `du` runs, so the hold never waits on it. Returns the new
  alerted level and the classified status.
  """
  @spec check(level(), keyword()) :: {level(), status()}
  def check(alerted, opts \\ []) do
    {alert_percent, stop_percent, floor_bytes} = Keyword.get(opts, :thresholds_fun, &thresholds/0).()
    sample = bounded(Keyword.get(opts, :sample_fun, &sample/0), Keyword.get(opts, :df_timeout_ms, @df_timeout_ms))
    thresholds = %{alert_percent: alert_percent, stop_percent: stop_percent, floor_bytes: floor_bytes}
    status = classify(sample, thresholds, Keyword.get(opts, :held, false))
    Keyword.get(opts, :publish_fun, &publish/1).(status)
    {next_alerted(alerted, status, Keyword.get(opts, :alert_fun, &Signal.alert/2), opts), status}
  end

  @doc "The last published status, `{:stale, age_ms}` once the watchdog stops sampling, or `nil` before the first sample."
  @spec current() :: status() | nil
  def current do
    case :ets.lookup(__MODULE__, :status) do
      [{:status, status}] -> fresh(status, now_ms())
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  @spec fresh(status() | nil, integer()) :: status() | nil
  def fresh(%{sampled_at_ms: at}, now_ms) when now_ms - at > @stale_ms, do: {:stale, now_ms - at}
  def fresh(status, _now_ms), do: status

  @doc "Admission gate: holds new dispatch only at the stop level; an unknown or stale sample fails open."
  @spec dispatch_gate(status() | nil) :: :dispatch | {:hold, map()}
  def dispatch_gate(status \\ current())

  def dispatch_gate(%{level: :stop, worst: worst} = status) do
    {:hold,
     %{
       signal: :disk,
       measured: worst.used_percent,
       threshold: status.stop_percent,
       detail: "mount=#{worst.mount} free=#{human(worst.free_bytes)} floor=#{human(status.floor_bytes)}"
     }}
  end

  def dispatch_gate(_status), do: :dispatch

  @doc "The `DISK` line of `aiur status`."
  @spec status_line(status() | nil, integer()) :: String.t()
  def status_line(status \\ current(), now_ms \\ now_ms())
  def status_line(nil, _now_ms), do: "DISK unknown (not sampled yet)"
  def status_line(:unknown, _now_ms), do: "DISK unknown (free-space sample failed or timed out)"
  def status_line({:stale, age_ms}, _now_ms), do: "DISK stale (last sample #{div(age_ms, 1000)}s ago; watchdog not sampling)"

  def status_line(%{worst: worst} = status, now_ms) do
    stopped =
      if status.level == :stop,
        do: "; new dispatch stopped until below #{status.stop_percent - @resume_margin_percent}% used",
        else: ""

    "DISK #{worst.mount} #{worst.used_percent}% used, #{human(worst.free_bytes)} free, " <>
      "sampled #{div(max(now_ms - status.sampled_at_ms, 0), 1000)}s ago " <>
      "(alert at #{status.alert_percent}%, dispatch stops at #{status.stop_percent}% or under #{human(status.floor_bytes)} free)#{stopped}"
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
    with [device, total, _used, avail, capacity | mount] <- String.split(row),
         {total_kb, ""} <- Integer.parse(total),
         {avail_kb, ""} <- Integer.parse(avail),
         {used_percent, "%"} <- Integer.parse(capacity),
         [_ | _] <- mount do
      [
        %{
          device: device,
          mount: Enum.join(mount, " "),
          used_percent: used_percent,
          free_bytes: avail_kb * 1024,
          size_bytes: total_kb * 1024
        }
      ]
    else
      _ -> []
    end
  end

  @impl true
  def init(opts) do
    # ETS, not :persistent_term: the status changes every minute and a put would force a global GC scan.
    :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true])
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
    {alerted, _status} = check(state.alerted, [{:held, match?(%{level: :stop}, current())} | state.opts])
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

  defp publish(status), do: :ets.insert(__MODULE__, {:status, status})

  defp classify(filesystems, thresholds, held?) when is_list(filesystems) and filesystems != [] do
    stopping = Enum.filter(filesystems, &stopping?(&1, thresholds, held?))
    worst = Enum.max_by(if(stopping == [], do: filesystems, else: stopping), & &1.used_percent)

    level =
      cond do
        stopping != [] -> :stop
        worst.used_percent >= thresholds.alert_percent -> :warn
        true -> :ok
      end

    Map.merge(thresholds, %{level: level, worst: worst, filesystems: filesystems, sampled_at_ms: now_ms()})
  end

  defp classify(_sample, _thresholds, _held?), do: :unknown

  # While held, both lines move by the resume margin, so 97 -> 96 -> 97 keeps the hold.
  defp stopping?(fs, thresholds, held?) do
    margin = if held?, do: @resume_margin_percent, else: 0

    fs.used_percent >= thresholds.stop_percent - margin or
      fs.free_bytes < thresholds.floor_bytes + div(fs.size_bytes * margin, 100)
  end

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
      largest = bounded(Keyword.get(opts, :largest_fun, &largest_workspaces/0), Keyword.get(opts, :du_timeout_ms, @du_timeout_ms))
      alert.(@topic, pressure_alert(status, largest))
      level
    else
      alerted
    end
  end

  defp pressure_alert(%{worst: worst} = status, largest) do
    action =
      if status.level == :stop,
        do: "New dispatch is stopped until usage drops below #{status.stop_percent - @resume_margin_percent}%.",
        else: "Dispatch stops at #{status.stop_percent}% or under #{human(status.floor_bytes)} free."

    message = "Disk #{worst.mount} (#{worst.device}) is #{worst.used_percent}% used, #{human(worst.free_bytes)} free"

    dirs =
      case largest do
        :unknown -> "unavailable (timed out)"
        [] -> "unavailable"
        dirs -> Enum.map_join(dirs, ", ", fn {path, bytes} -> "#{path} #{human(bytes)}" end)
      end

    Logger.warning("disk_watchdog pressure mount=#{worst.mount} used_percent=#{worst.used_percent} free_bytes=#{worst.free_bytes}")

    [
      message: message,
      reason: "#{message}. #{action} Largest workspace directories: #{dirs}. Free space before the daemon crashes on a full disk.",
      needs_attention: true,
      severity: if(status.level == :stop, do: "critical", else: "warning")
    ]
  end

  # A hung mount or a minutes-long `du` must not freeze the watchdog; a timeout is `:unknown`.
  # ponytail: the killed task leaves the OS process to die on its closed pipe; a `df` stuck in D state cannot be killed at all.
  defp bounded(fun, timeout_ms) do
    task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout_or_exit -> :unknown
    end
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

  # Runs only when an alert fires, under `bounded/2`.
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
    {monitoring.disk_alert_percent, monitoring.disk_stop_dispatch_percent, monitoring.disk_stop_dispatch_free_gb * @gib}
  rescue
    _error -> {90, 97, 10 * @gib}
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp human(bytes) when bytes >= 1_099_511_627_776, do: "#{Float.round(bytes / 1_099_511_627_776, 1)} TiB"
  defp human(bytes) when bytes >= @gib, do: "#{Float.round(bytes / @gib, 1)} GiB"
  defp human(bytes), do: "#{div(bytes, 1_048_576)} MiB"
end
