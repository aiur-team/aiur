defmodule Aiur.ExecutorSweep do
  @moduledoc "Periodic local-state checks that keep Executor actions visible."
  use GenServer
  require Logger

  alias Aiur.Executor.StatePaths
  alias Aiur.ExecutorSweep.{Checks, SnapshotCache}
  alias Aiur.ExecutorSweep.Wake
  alias Aiur.Instance.SweepFilter
  alias Aiur.JsonStore

  @interval_ms 5 * 60 * 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec findings(keyword()) :: [map()]
  def findings(opts \\ []) do
    snapshot = Keyword.get_lazy(opts, :snapshot, &SnapshotCache.read/0)
    snapshot = SweepFilter.own(snapshot)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    threshold = Keyword.get(opts, :unreviewed_pr_minutes, configured_threshold())

    Checks.all(snapshot, now,
      unreviewed_pr_minutes: threshold,
      label_prefix: configured_label_prefix()
    )
  end

  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    findings = findings(opts)

    if Keyword.get(opts, :json, false) do
      result = %{findings: findings}
      result = if Keyword.get(opts, :apply, false), do: Map.put(result, :applied, []), else: result
      IO.puts(Jason.encode!(result))
    else
      if findings == [], do: IO.puts("Executor sweep: no findings")
      Enum.each(findings, &IO.puts("P#{&1.priority} #{&1.message} Action: #{&1.action}"))
      if Keyword.get(opts, :apply, false), do: IO.puts("No safe reversible actions are available to apply.")
    end

    :ok
  end

  @impl true
  def init(opts) do
    # An interval of 0 disables the timer (the shared test app stays idle).
    interval_ms = Keyword.get_lazy(opts, :interval_ms, fn -> Application.get_env(:aiur, :executor_sweep_interval_ms, @interval_ms) end)
    if interval_ms > 0, do: send(self(), :sweep)

    seen_path = Keyword.get_lazy(opts, :seen_path, &StatePaths.sweep_seen_path/0)
    seen = read_seen(seen_path)

    {:ok,
     %{
       seen: seen || MapSet.new(),
       seeded?: seen != nil,
       seen_path: seen_path,
       sweep_fun: Keyword.get(opts, :sweep_fun, &findings/0),
       publish_fun: Keyword.get(opts, :publish_fun, &publish/1),
       interval_ms: interval_ms
     }}
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, state.interval_ms)

    case safe_sweep(state.sweep_fun) do
      {:ok, findings} ->
        complete? = not Enum.any?(findings, &(&1.kind == "sweep_source_unavailable"))
        # Without a seen file, the first sweep and the first complete one record the backlog instead of waking on it.
        quiet? = not state.seeded? and (complete? or state.seen == MapSet.new())
        unless quiet?, do: findings |> Enum.reject(&(fingerprint(&1) in state.seen)) |> Enum.each(state.publish_fun)
        {:noreply, record_seen(state, findings, complete?)}

      :error ->
        {:noreply, state}
    end
  end

  # An unavailable source hides its findings only for now; keep their fingerprints so they do not wake again.
  defp record_seen(state, findings, complete?) do
    fingerprints = MapSet.new(findings, &fingerprint/1)
    seen = if complete?, do: fingerprints, else: MapSet.union(state.seen, fingerprints)
    seeded? = state.seeded? or complete?
    if seeded? and (seen != state.seen or not state.seeded?), do: write_seen(state.seen_path, seen)
    %{state | seen: seen, seeded?: seeded?}
  end

  # A dependency that is down or still starting must not crash the sweep, or restarts can exhaust the app supervisor.
  defp safe_sweep(sweep_fun) do
    {:ok, sweep_fun.()}
  rescue
    error -> skipped(:error, error)
  catch
    :exit, reason -> skipped(:exit, reason)
  end

  defp skipped(kind, reason) do
    Logger.warning("Executor sweep skipped a cycle: " <> Exception.format_banner(kind, reason))
    :error
  end

  # `seen` survives a restart, so a boot re-publishes only findings that changed.
  # A missing or unreadable file is nil: the sweep seeds it instead of publishing everything.
  defp read_seen(path) do
    case JsonStore.read(path) do
      {:ok, list} when is_list(list) -> MapSet.new(list)
      {:ok, nil} -> nil
      other -> skipped_seen(:read, other)
    end
  end

  defp write_seen(path, fingerprints) do
    JsonStore.write!(path, Enum.sort(fingerprints))
  rescue
    error -> skipped_seen(:write, error)
  end

  defp skipped_seen(op, reason) do
    Logger.warning("Executor sweep could not #{op} its published findings: #{inspect(reason)}")
    nil
  end

  defp publish(finding), do: Wake.publish(finding)

  defp fingerprint(finding) do
    finding
    |> Map.take([
      :kind,
      :ticket,
      :ticket_count,
      :oldest_ticket,
      :truncated?,
      :issue_number,
      :pull_request,
      :head_sha,
      :decision,
      :merge_group,
      :queue_set,
      :service,
      :failure_class,
      :failed_checks,
      :check,
      :sources
    ])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp configured_threshold do
    case Aiur.Config.settings() do
      {:ok, settings} -> settings.executor.sweep.unreviewed_pr_minutes
      _ -> 10
    end
  end

  defp configured_label_prefix do
    case Aiur.Config.settings() do
      {:ok, %{tracker: %{github: %{label_prefix: prefix}}}} when is_binary(prefix) and prefix != "" -> prefix
      _ -> "agent"
    end
  end
end
