defmodule AiurWeb.OperatorControlCenter.Analytics.Presenter do
  @moduledoc """
  Reshapes the durable `Aiur.RunTelemetry` dataset into the analytics view
  model: a bucketed per-actor resource series, run KPIs, and per-ticket
  lifecycle rows plus a dispatch-time complexity breakdown. Pure `model/2` is driven by an already-built dataset so it is
  unit-testable against a fixture; `load/1` resolves the live telemetry file,
  concurrency cap, core count, and host memory before delegating to it.

  The same model serves latest-run, Build Order, and cross-boot scopes. Current
  sessions use the live boot when available and otherwise fall back to retained
  telemetry; Build Order refreshes use a bounded active timeline.
  """

  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.{Dataset, SummaryMerge, Timeline}
  alias AiurWeb.OperatorControlCenter.Analytics.{ConcurrencyCoverage, LatestRun, Optimistic, Pressure, RuntimeCaps, TicketRow, WastedCapacity}

  import Pressure, only: [actor_kind: 2, actor_summary: 2, bucket_actor: 5, bucket_pressure: 5, build_series: 7, timeline: 4, window: 3]

  @default_buckets 180
  @max_series_actors 8
  @default_host_mem_bytes 32 * 1024 * 1024 * 1024
  @default_cap 10

  @type model :: %{
          available?: boolean(),
          retained_runs: map() | nil,
          window: %{start_ms: integer(), end_ms: integer(), buckets: pos_integer()},
          source_boot_id: String.t() | nil,
          source_observed_at: String.t() | nil,
          cap: non_neg_integer() | nil,
          cap_available?: boolean(),
          configured_cap: non_neg_integer() | nil,
          session_cap: non_neg_integer() | nil,
          cap_binding: String.t() | nil,
          cap_staleness: {:stale | :retained, non_neg_integer()} | nil,
          live_concurrency: non_neg_integer() | nil,
          live_occupied: non_neg_integer() | nil,
          live_concurrency_state: atom() | {atom(), non_neg_integer() | nil} | nil,
          cores: pos_integer(),
          cpu_ceiling: number(),
          host_mem_bytes: number(),
          actors: [map()],
          series: [map()],
          pressure: map(),
          tickets: [map()],
          complexity_breakdown: [map()],
          complexity_count_ticks: [non_neg_integer()],
          kpis: map()
        }

  @doc """
  Loads the durable run telemetry and builds the analytics model, or reports why
  it is unavailable.

  Scope options:

    * `:session` — `:current` narrows to one daemon boot, `:cross` reads the
      current boot live from raw (bounded tail) and every prior boot from its
      materialized run summary, `:all` (default) keeps every session in the
      stream.
    * `:tickets` — a list or `MapSet` of bare ticket-number strings to scope to.
    * `:timeline` — `:absolute` (default) or `:active` to elide idle gaps.
    * `:scope_total` — burn-up denominator when the scope knows its own size
      (a Build Order's member count) rather than inferring it from telemetry.

  Unavailable reasons distinguish an idle fleet from a persistence failure:
  `:no_telemetry` means nothing analyzable was recorded, `:retained_scan_limited`
  means no retained summary fit the cold scan budget, `:retained_unreadable` means
  retained summaries could not be decoded, and `:error` is an unexpected failure.
  """
  @spec load(keyword()) :: {:ok, model()} | {:unavailable, atom()}
  def load(opts \\ []) do
    file = Keyword.get(opts, :telemetry_file) || RunTelemetry.telemetry_file()
    analyzable? = fn dataset -> dataset |> scope(opts) |> dataset_analyzable?() end

    result =
      case Keyword.get(opts, :session, :all) do
        # Forward the caller opts so the latest-run loader's documented test
        # seams (`:cache_identity`, `:prior_loader`) stay reachable through
        # this boundary; they default to production reads otherwise.
        :current ->
          LatestRun.load(file, current_boot_id(), analyzable?, opts)

        :cross ->
          cross_session(file, opts)

        _other ->
          Dataset.build(file, [])
      end

    case result do
      {:ok, dataset} ->
        dataset |> scope(opts) |> analyzable(opts)

      {:error, {:no_telemetry_files, _paths}} ->
        {:unavailable, :no_telemetry}

      {:error, reason} when reason in [:retained_unreadable, :retained_scan_limited] ->
        {:unavailable, reason}
    end
  rescue
    _error -> {:unavailable, :error}
  end

  defp cross_session(file, opts), do: SummaryMerge.load(file, current_boot_id(), opts)

  # A readable stream that contains nothing for this scope is "no telemetry", not
  # a zero-cost build: rendering empty charts and zeroed KPIs would claim a build
  # burned nothing when in truth none of its members has run yet.
  defp analyzable(dataset, opts) do
    if dataset_analyzable?(dataset) do
      {:ok, model(dataset, RuntimeCaps.runtime_opts(opts))}
    else
      {:unavailable, :no_telemetry}
    end
  end

  defp dataset_analyzable?(dataset) do
    not Enum.empty?(Map.get(dataset, :tickets, %{})) or any_agent_actor?(dataset)
  end

  defp any_agent_actor?(dataset) do
    dataset |> Map.get(:actors, %{}) |> Enum.any?(fn {key, actor} -> actor_kind(key, actor) == :agent end)
  end

  # Scope handling.
  defp scope(dataset, opts) do
    boot_id = session_boot_id(dataset, Keyword.get(opts, :session, :all))
    tickets = ticket_set(Keyword.get(opts, :tickets))

    if is_nil(boot_id) and is_nil(tickets) do
      dataset
    else
      Dataset.filter(dataset, boot_id: boot_id, tickets: tickets)
    end
  end

  defp session_boot_id(_dataset, :all), do: nil
  defp session_boot_id(_dataset, :cross), do: nil

  # The current boot is the live session whenever the daemon is writing. When the
  # stream predates this boot — a dashboard opened before anything was recorded —
  # the newest boot in the stream is still the most recent session, and showing it
  # beats blanking the page.
  defp session_boot_id(dataset, :current) do
    boots = Dataset.boot_ids(dataset)
    current = current_boot_id()

    cond do
      materialized_single_boot?(dataset, boots) -> nil
      current in boots -> current
      true -> List.last(boots)
    end
  end

  # A run summary is already reduced to exactly one boot. Filtering it by that
  # same boot would unnecessarily re-reduce its cached ticket events instead of
  # preserving the materialized intervals.
  defp materialized_single_boot?(dataset, [_boot_id]),
    do: get_in(dataset, [:provenance, :generated_by]) == "analytics/reduce"

  defp materialized_single_boot?(_dataset, _boots), do: false

  defp current_boot_id do
    RunTelemetry.boot_id()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp ticket_set(nil), do: nil
  defp ticket_set(%MapSet{} = tickets), do: tickets
  defp ticket_set(tickets) when is_list(tickets), do: tickets |> Enum.filter(&is_binary/1) |> MapSet.new()
  defp ticket_set(_tickets), do: nil

  @doc "Builds the analytics view model from an already-reduced telemetry dataset."
  @spec model(map(), keyword()) :: model()
  def model(dataset, opts \\ []) do
    cap = Keyword.get(opts, :cap, @default_cap)
    cap_available? = Keyword.get(opts, :cap_available?, is_integer(cap))
    configured_cap = Keyword.get(opts, :configured_cap, cap)
    session_cap = Keyword.get(opts, :session_cap, cap)
    cap_binding = Keyword.get(opts, :cap_binding)
    cap_staleness = Keyword.get(opts, :cap_staleness)
    cores = Keyword.get(opts, :cores, System.schedulers_online())
    host_mem = Keyword.get(opts, :host_mem_bytes, @default_host_mem_bytes)
    buckets = Keyword.get(opts, :buckets, @default_buckets)

    actors = Map.get(dataset, :actors, %{})
    tickets = Map.get(dataset, :tickets, %{})
    {t0, t1} = window(dataset, actors, opts)
    timeline = timeline(dataset, actors, {t0, t1}, opts)
    axis0 = Timeline.project(timeline, t0)
    axis1 = Timeline.project(timeline, t1)
    bw = max((axis1 - axis0) / buckets, 1)

    summaries = actors |> Enum.map(fn {key, a} -> actor_summary(key, a) end) |> Enum.sort_by(& &1.cpu_seconds, :desc)

    display =
      summaries
      |> Enum.filter(&(&1.kind == :agent and &1.cpu_seconds > 0))
      |> Enum.take(@max_series_actors)
      |> Enum.with_index(1)
      |> Enum.map(fn {actor, i} -> Map.put(actor, :color_i, i) end)

    display_keys = MapSet.new(display, & &1.key)

    bucketed =
      Map.new(actors, fn {key, a} ->
        {key, {actor_kind(key, a), bucket_actor(Map.get(a, :samples, []), timeline, axis0, bw, buckets)}}
      end)

    pressure_buckets =
      actors
      |> Map.get("_daemon", %{})
      |> Map.get(:samples, [])
      |> bucket_pressure(timeline, axis0, bw, buckets)

    series = build_series(bucketed, pressure_buckets, display, display_keys, axis0, bw, buckets) |> ConcurrencyCoverage.mark_unknown(bucketed, opts)

    kpis =
      compute_kpis(
        series,
        tickets,
        %{cap: cap, cap_available?: cap_available?, cores: cores, host_mem: host_mem, bw: bw, dataset: dataset},
        opts
      )

    complexity_breakdown = complexity_breakdown(tickets)
    complexity_count_ticks = complexity_count_ticks(complexity_breakdown)

    rows =
      tickets
      |> Enum.map(fn {id, t} -> TicketRow.build(id, t, &Timeline.project(timeline, &1)) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.start_ms)

    %{
      available?: true,
      retained_runs: Map.get(dataset, :retained_runs),
      window: %{start_ms: axis0, end_ms: axis1, buckets: buckets},
      source_boot_id: single_boot_id(dataset),
      source_observed_at: get_in(dataset, [:provenance, :time_range, :end]),
      cap: cap,
      cap_available?: cap_available?,
      configured_cap: configured_cap,
      session_cap: session_cap,
      cap_binding: cap_binding,
      cap_staleness: cap_staleness,
      live_concurrency: Keyword.get(opts, :live_concurrency),
      live_occupied: Keyword.get(opts, :live_occupied),
      live_concurrency_state: Keyword.get(opts, :live_concurrency_state),
      cores: cores,
      cpu_ceiling: cores * 100,
      host_mem_bytes: host_mem,
      actors: display,
      series: series,
      pressure: pressure_summary(series),
      tickets: rows,
      complexity_breakdown: complexity_breakdown,
      complexity_count_ticks: complexity_count_ticks,
      kpis: kpis
    }
  end

  defp single_boot_id(dataset) do
    case Dataset.boot_ids(dataset) do
      [boot_id] -> boot_id
      _other -> nil
    end
  end

  @doc """
  Formats the effective agent cap with everything needed to act on it.

  Three facts travel with the number, because the bare figure is what made
  #2241 possible:

    * the *binding constraint* — `2 cap` reads identically whether an AIMD
      envelope backed off, a session override lowered the ceiling, or paused
      reservations are holding slots, and each wants a different response;
    * the *other ceilings* — the session ceiling `aiur status` prints and the
      configured value in `.aiur/config`, whenever either differs from the
      effective cap, so the two surfaces never contradict each other;
    * the *age* — a retained snapshot renders, per the `SnapshotStore`
      contract, but never unmarked. A confident cap from an hour-old reading is
      the failure this page already had once (#1564).

  An absent effective fact renders `unknown cap`, never a silent substitution
  of the configured value in either direction.
  """
  @spec cap_label(model()) :: String.t()
  defdelegate cap_label(model), to: RuntimeCaps

  @doc """
  Renders idle slot-hours, or an em dash when no effective cap was reported.

  Kept beside `cap_label/1` so every surface spells the unknown the same way:
  the figure is a subtraction from the cap, so an unknown cap has no figure.
  """
  @spec wasted_slot_hours_label(number() | nil) :: String.t()
  def wasted_slot_hours_label(hours) when is_number(hours), do: "#{hours}h"
  def wasted_slot_hours_label(_hours), do: "—"

  @doc false
  @spec pressure_summary([map()]) :: map()
  defdelegate pressure_summary(series), to: Pressure

  # ---- KPIs ----

  defp compute_kpis(series, tickets, ctx, opts) do
    ceiling = ctx.cores * 100
    concs = Enum.map(series, & &1.conc)
    peak_conc = Enum.max([0 | Enum.filter(concs, &is_integer/1)])
    conc_now = if concs == [], do: 0, else: List.last(concs)
    mean_cpu = mean(Enum.sum(Enum.map(series, & &1.total_cpu)), length(series))
    mem_now = (List.last(series) || %{}) |> Map.get(:total_mem, 0)
    bucket_hours = ctx.bw / 1000 / 3600
    {wasted, wasted_partial?} = WastedCapacity.summarize(series, bucket_hours, ctx.cap_available?)
    merged = Enum.count(tickets, fn {_id, t} -> merged?(t) end)
    # A Build Order knows its own size; telemetry only knows the tickets that ran,
    # so inferring scope from it would report a build complete before it started.
    total = Keyword.get(opts, :scope_total) || map_size(tickets)

    %{
      peak_conc: peak_conc,
      conc_now: conc_now,
      cap: ctx.cap,
      mean_util_pct: pct(mean_cpu, ceiling),
      mem_headroom_pct: max(round((1 - mem_now / max(ctx.host_mem, 1)) * 100), 0),
      mem_now_bytes: mem_now,
      merged: merged,
      done: merged,
      total: total,
      done_pct: pct(merged, total),
      wasted_slot_hours: wasted,
      wasted_slot_hours_partial: wasted_partial?,
      sessions: ctx.dataset |> Dataset.boot_ids() |> length(),
      active_ms: round(ctx.bw * length(series)),
      cpu_hours: round1(cpu_hours(ctx.dataset)),
      optimistic: Optimistic.summary(tickets)
    }
  end

  # Total CPU burned by the scope's agent actors, from the per-actor profile so it
  # is independent of bucket resolution.
  defp cpu_hours(dataset) do
    dataset
    |> Map.get(:actors, %{})
    |> Enum.filter(fn {key, actor} -> actor_kind(key, actor) == :agent end)
    |> Enum.map(fn {key, actor} -> actor_summary(key, actor).cpu_seconds end)
    |> Enum.sum()
    |> Kernel./(3600)
  end

  defp merged?(ticket) do
    ticket |> Map.get(:intervals, []) |> Enum.any?(&(Map.get(&1, :phase) == "pr_merged"))
  end

  # Complexity is recorded on the dispatch lifecycle event, so this grouping
  # remains historical even if a tracker label changes after the run. A ticket
  # contributes to its tier's count when it was dispatched; its average uses
  # the observed wall-clock span from dispatch through the latest lifecycle
  # boundary (open work is therefore still useful, but naturally provisional).
  defp complexity_breakdown(tickets) do
    samples =
      tickets
      |> Enum.map(fn {_id, ticket} -> {Map.get(ticket, :complexity), ticket_wall_clock_ms(ticket)} end)
      |> Enum.filter(fn {complexity, _duration_ms} -> is_integer(complexity) and complexity in 1..5 end)

    for tier <- 1..5 do
      tier_samples = Enum.filter(samples, fn {complexity, _duration_ms} -> complexity == tier end)
      durations = tier_samples |> Enum.map(&elem(&1, 1)) |> Enum.filter(&is_integer/1)

      %{
        tier: tier,
        count: length(tier_samples),
        average_wall_clock_ms: average_integer(durations)
      }
    end
  end

  @doc "Integer ticket-count ticks for the complexity breakdown axis."
  @spec complexity_count_ticks([map()]) :: [non_neg_integer()]
  def complexity_count_ticks(tiers) do
    maximum = tiers |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end) |> max(1)
    step = nice_tick_step(div(maximum + 4, 5))
    axis_max = div(maximum + step - 1, step) * step

    Enum.to_list(0..axis_max//step)
  end

  defp nice_tick_step(target) do
    magnitude = Integer.pow(10, length(Integer.digits(target)) - 1)

    cond do
      target <= magnitude -> magnitude
      target <= magnitude * 2 -> magnitude * 2
      target <= magnitude * 5 -> magnitude * 5
      true -> magnitude * 10
    end
  end

  defp ticket_wall_clock_ms(ticket) do
    intervals = Map.get(ticket, :intervals, [])

    dispatch_ms =
      ticket
      |> Map.get(:events, [])
      |> Enum.find_value(fn
        %{event: "dispatch", timestamp_ms: timestamp_ms} when is_integer(timestamp_ms) -> timestamp_ms
        _event -> nil
      end)

    starts = intervals |> Enum.map(&Map.get(&1, :start_ms)) |> Enum.filter(&is_integer/1)

    ends =
      intervals
      |> Enum.flat_map(fn interval -> [Map.get(interval, :end_ms), Map.get(interval, :start_ms)] end)
      |> Enum.filter(&is_integer/1)

    start_ms = dispatch_ms || Enum.min(starts, fn -> nil end)
    end_ms = Enum.max(ends, fn -> nil end)

    if is_integer(start_ms) and is_integer(end_ms), do: max(end_ms - start_ms, 0)
  end

  defp average_integer([]), do: nil
  defp average_integer(values), do: round(Enum.sum(values) / length(values))

  defp pct(_num, 0), do: 0
  defp pct(num, denom), do: round(num / denom * 100)

  defp mean(_sum, 0), do: 0.0
  defp mean(sum, n), do: sum / n

  defp round1(v) when is_number(v), do: Float.round(v * 1.0, 1)
  defp round1(_v), do: 0.0
end
