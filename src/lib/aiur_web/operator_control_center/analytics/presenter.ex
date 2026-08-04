defmodule AiurWeb.OperatorControlCenter.Analytics.Presenter do
  @moduledoc """
  Reshapes the durable `Aiur.RunTelemetry` dataset into the analytics view
  model: a bucketed per-actor resource series, run KPIs, and per-ticket
  lifecycle rows plus a dispatch-time complexity breakdown. Pure `model/2` is driven by an already-built dataset so it is
  unit-testable against a fixture; `load/1` resolves the live telemetry file,
  concurrency cap, core count, and host memory before delegating to it.

  The same model serves two scopes. The live-session view passes
  `session: :current` and gets absolute timestamps over one daemon boot. The
  Build Order view passes the selected member ticket set, `session: :current`,
  and `timeline: :active`. That keeps its recurring refresh a bounded tail read;
  cross-session reporting belongs to a materialized summary rather than a live
  full-stream parse. Both feed the same `Charts`, whose axis already labels ticks
  as elapsed time.
  """

  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.{Dataset, Summaries, Timeline}

  @default_buckets 180
  @max_series_actors 8
  @default_host_mem_bytes 32 * 1024 * 1024 * 1024
  @default_cap 10

  @type model :: %{
          available?: boolean(),
          window: %{start_ms: integer(), end_ms: integer(), buckets: pos_integer()},
          cap: non_neg_integer(),
          cores: pos_integer(),
          cpu_ceiling: number(),
          host_mem_bytes: number(),
          actors: [map()],
          series: [map()],
          tickets: [map()],
          complexity_breakdown: [map()],
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
  """
  @spec load(keyword()) :: {:ok, model()} | {:unavailable, atom()}
  def load(opts \\ []) do
    file = Keyword.get(opts, :telemetry_file) || RunTelemetry.telemetry_file()

    result =
      case Keyword.get(opts, :session, :all) do
        :current ->
          Dataset.build(file, session: :current, boot_id: current_boot_id())

        :cross ->
          cross_session(file)

        _other ->
          Dataset.build(file, [])
      end

    case result do
      {:ok, dataset} -> dataset |> scope(opts) |> analyzable(opts)
      {:error, {:no_telemetry_files, _paths}} -> {:unavailable, :no_telemetry}
    end
  rescue
    _error -> {:unavailable, :error}
  end

  # Cross-session view: the current boot is read live from raw (bounded tail so
  # it stays fresh on the 30 s tick); every prior boot is read from its
  # materialized run summary instead of re-parsing the retained stream. When no
  # summaries exist yet this falls back to the historical full raw parse so the
  # Full-log view keeps working before the first materialization.
  defp cross_session(file) do
    current = current_boot_id()
    prior = Summaries.load_prior_datasets(current)

    if prior == [] do
      Dataset.build(file, [])
    else
      case Dataset.build(file, session: :current, boot_id: current) do
        {:ok, current_dataset} -> {:ok, merge_datasets([current_dataset | prior])}
        {:error, _reason} -> {:ok, merge_datasets(prior)}
      end
    end
  end

  defp merge_datasets(datasets) do
    datasets
    |> Dataset.merge()
    |> Map.put(:provenance, merge_provenance(datasets))
  end

  defp merge_provenance(datasets) do
    provenances = Enum.map(datasets, & &1.provenance)
    files = provenances |> Enum.flat_map(& &1.files) |> Enum.uniq()
    inputs = provenances |> Enum.flat_map(& &1.inputs) |> Enum.uniq()
    schema_versions = provenances |> Enum.flat_map(& &1.schema_versions) |> Enum.uniq() |> Enum.sort()
    record_count = provenances |> Enum.reduce(0, &(&1.record_count + &2))

    time_range =
      case {provenances |> Enum.map(& &1.time_range) |> Enum.reject(&is_nil/1), []} do
        {[], _} -> nil
        {ranges, _} -> %{start: ranges |> Enum.map(& &1.start) |> Enum.min(), end: ranges |> Enum.map(& &1.end) |> Enum.max()}
      end

    %{
      inputs: inputs,
      files: files,
      schema_versions: schema_versions,
      time_range: time_range,
      record_count: record_count,
      enrich: Enum.any?(provenances, &Map.get(&1, :enrich, false)),
      generated_by: "presenter:cross"
    }
  end

  # A readable stream that contains nothing for this scope is "no telemetry", not
  # a zero-cost build: rendering empty charts and zeroed KPIs would claim a build
  # burned nothing when in truth none of its members has run yet.
  defp analyzable(dataset, opts) do
    if Enum.empty?(Map.get(dataset, :tickets, %{})) and not any_agent_actor?(dataset) do
      {:unavailable, :no_telemetry}
    else
      {:ok, model(dataset, runtime_opts(opts))}
    end
  end

  defp any_agent_actor?(dataset) do
    dataset |> Map.get(:actors, %{}) |> Enum.any?(fn {key, actor} -> actor_kind(key, actor) == :agent end)
  end

  # ---- scope ----

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

    if current in boots, do: current, else: List.last(boots)
  end

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

    series = build_series(bucketed, display, display_keys, axis0, bw, buckets)
    kpis = compute_kpis(series, tickets, %{cap: cap, cores: cores, host_mem: host_mem, bw: bw, dataset: dataset}, opts)
    complexity_breakdown = complexity_breakdown(tickets)

    rows =
      tickets
      |> Enum.map(fn {id, t} -> ticket_row(id, t, timeline) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.start_ms)

    %{
      available?: true,
      window: %{start_ms: axis0, end_ms: axis1, buckets: buckets},
      cap: cap,
      cores: cores,
      cpu_ceiling: cores * 100,
      host_mem_bytes: host_mem,
      actors: display,
      series: series,
      tickets: rows,
      complexity_breakdown: complexity_breakdown,
      kpis: kpis
    }
  end

  # ---- per-actor summary ----

  defp actor_summary(key, actor) do
    profile = Map.get(actor, :profile, %{})
    cpu = Map.get(profile, "cpu_percent", %{})
    rss = Map.get(profile, "rss_bytes", %{})
    count = Map.get(cpu, :count, 0)
    mean = Map.get(cpu, :mean, 0.0) || 0.0
    # CPU-seconds ≈ mean fraction of a core × sampled span (5 s cadence).
    cpu_seconds = round(mean / 100 * count * 5)

    %{
      key: key,
      label: actor_label(key),
      kind: actor_kind(key, actor),
      cpu_seconds: cpu_seconds,
      peak_cpu: round1(Map.get(cpu, :max, 0.0) || 0.0),
      peak_mem_bytes: round(Map.get(rss, :max, 0) || 0)
    }
  end

  # ---- bucketing ----

  defp bucket_actor(samples, timeline, axis0, bw, buckets) do
    samples
    |> Enum.reduce(%{}, fn s, acc -> accumulate_sample(acc, s, timeline, axis0, bw, buckets) end)
    |> Map.new(fn {b, {cs, cn, rs, rn}} -> {b, %{cpu: mean(cs, cn), rss: mean(rs, rn)}} end)
  end

  defp accumulate_sample(acc, sample, timeline, axis0, bw, buckets) do
    ts = Map.get(sample, :timestamp_ms)

    if is_integer(ts) and Map.get(sample, :availability) == "measured" do
      index = bucket_index(Timeline.project(timeline, ts), axis0, bw, buckets)
      add_cell(acc, index, num(Map.get(sample, "cpu_percent")), num(Map.get(sample, "rss_bytes")))
    else
      acc
    end
  end

  defp add_cell(acc, b, cpu, rss) do
    Map.update(acc, b, {cpu || 0.0, bool01(cpu), rss || 0.0, bool01(rss)}, fn {cs, cn, rs, rn} ->
      {cs + (cpu || 0.0), cn + bool01(cpu), rs + (rss || 0.0), rn + bool01(rss)}
    end)
  end

  defp bucket_index(ts, t0, bw, buckets), do: ((ts - t0) / bw) |> trunc() |> clamp(0, buckets - 1)

  defp build_series(bucketed, display, display_keys, t0, bw, buckets) do
    for b <- 0..(buckets - 1) do
      bucketed
      |> Enum.reduce({0.0, 0.0, 0.0, 0.0, 0, %{}}, &fold_cell(&1, &2, b, display_keys))
      |> series_bucket(b, t0, bw, display)
    end
  end

  defp fold_cell({key, {kind, arr}}, {ex, ot, tc, tm, cc, per}, b, display_keys) do
    cell = Map.get(arr, b, %{cpu: 0.0, rss: 0.0})
    cpu = cell.cpu
    tc = tc + cpu
    tm = tm + cell.rss
    cc = if kind == :agent and cpu > 0, do: cc + 1, else: cc

    cond do
      kind in [:operator, :daemon] -> {ex + cpu, ot, tc, tm, cc, per}
      MapSet.member?(display_keys, key) -> {ex, ot, tc, tm, cc, Map.put(per, key, cpu)}
      true -> {ex, ot + cpu, tc, tm, cc, per}
    end
  end

  defp series_bucket({exec, other, total_cpu, total_mem, conc, per}, b, t0, bw, display) do
    %{
      idx: b,
      t_ms: round(t0 + b * bw + bw / 2),
      exec_cpu: round1(exec),
      other_cpu: round1(other),
      total_cpu: round1(total_cpu),
      total_mem: round(total_mem),
      conc: conc,
      per: Map.new(display, fn a -> {a.key, round1(Map.get(per, a.key, 0.0))} end)
    }
  end

  # ---- KPIs ----

  defp compute_kpis(series, tickets, ctx, opts) do
    ceiling = ctx.cores * 100
    concs = Enum.map(series, & &1.conc)
    peak_conc = Enum.max([0 | concs])
    conc_now = List.last(concs) || 0
    mean_cpu = mean(Enum.sum(Enum.map(series, & &1.total_cpu)), length(series))
    mem_now = (List.last(series) || %{}) |> Map.get(:total_mem, 0)
    bucket_hours = ctx.bw / 1000 / 3600
    wasted = series |> Enum.reduce(0.0, fn s, acc -> acc + max(ctx.cap - s.conc, 0) * bucket_hours end)
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
      wasted_slot_hours: round1(wasted),
      sessions: ctx.dataset |> Dataset.boot_ids() |> length(),
      active_ms: round(ctx.bw * length(series)),
      cpu_hours: round1(cpu_hours(ctx.dataset))
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

  # ---- ticket lifecycle rows ----

  defp ticket_row(id, ticket, timeline) do
    intervals = Map.get(ticket, :intervals, [])
    starts = intervals |> Enum.map(&Map.get(&1, :start_ms)) |> Enum.filter(&is_integer/1)

    if starts == [] do
      nil
    else
      ends = intervals |> Enum.map(fn iv -> Map.get(iv, :end_ms) || Map.get(iv, :start_ms) end) |> Enum.filter(&is_integer/1)
      start_ms = Enum.min(starts)
      work_ms = phase_start(intervals, ["implement", "agent_spinup", "build_test"]) || start_ms
      merged_at = phase_start(intervals, ["pr_merged"])
      end_ms = merged_at || Enum.max([start_ms | ends])
      project = &Timeline.project(timeline, &1)

      %{
        id: id,
        start_ms: project.(start_ms),
        work_ms: project.(work_ms),
        end_ms: project.(end_ms),
        merged_at: merged_at && project.(merged_at),
        status: ticket_status(intervals, merged_at)
      }
    end
  end

  defp ticket_status(intervals, merged_at) do
    phases = intervals |> Enum.map(&Map.get(&1, :phase)) |> MapSet.new()

    cond do
      merged_at -> :merged
      MapSet.member?(phases, "rework_start") -> :rework
      MapSet.member?(phases, "agent_pause") -> :paused
      true -> :active
    end
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

  defp phase_start(intervals, phases) do
    intervals
    |> Enum.filter(&(Map.get(&1, :phase) in phases and is_integer(Map.get(&1, :start_ms))))
    |> Enum.map(&Map.get(&1, :start_ms))
    |> case do
      [] -> nil
      list -> Enum.min(list)
    end
  end

  # ---- window + axis ----

  # The axis the model is drawn on. `:absolute` keeps wall-clock milliseconds,
  # which is right for one continuous session. `:active` elides the idle
  # stretches between sessions so a multi-week Build Order is charted over the
  # hours it was actually running.
  defp timeline(dataset, actors, window, opts) do
    case Keyword.get(opts, :timeline, :absolute) do
      :active -> Timeline.active(activity_ms(dataset, actors, window), opts)
      _absolute -> Timeline.identity()
    end
  end

  defp activity_ms(dataset, actors, {t0, t1}) do
    sample_ms =
      actors
      |> Enum.flat_map(fn {_key, a} -> Map.get(a, :samples, []) end)
      |> Enum.map(&Map.get(&1, :timestamp_ms))

    ticket_ms =
      dataset
      |> Map.get(:tickets, %{})
      |> Enum.flat_map(fn {_id, t} -> Map.get(t, :intervals, []) end)
      |> Enum.flat_map(fn iv -> [Map.get(iv, :start_ms), Map.get(iv, :end_ms)] end)

    Enum.filter(sample_ms ++ ticket_ms, &(is_integer(&1) and &1 >= t0 and &1 <= t1))
  end

  defp window(dataset, actors, opts) do
    {full0, full1} = full_window(dataset, actors)
    {run0, run1} = active_window(dataset, actors, {full0, full1})

    case Keyword.get(opts, :range, :run) do
      :full ->
        {full0, full1}

      {from_ms, to_ms} when is_integer(from_ms) and is_integer(to_ms) and to_ms > from_ms ->
        {max(from_ms, full0), min(to_ms, full1)}

      hours when is_number(hours) and hours > 0 ->
        {max(run1 - round(hours * 3600 * 1000), full0), run1}

      _run ->
        {run0, run1}
    end
  end

  # The run window is the span of real ticket lifecycle activity (dispatch →
  # work → merge), not the daemon's or an idle agent process's full lifetime.
  defp active_window(dataset, actors, {full0, full1}) do
    ticket_ms =
      dataset
      |> Map.get(:tickets, %{})
      |> Enum.flat_map(fn {_id, t} -> Map.get(t, :intervals, []) end)
      |> Enum.flat_map(fn iv -> [Map.get(iv, :start_ms), Map.get(iv, :end_ms)] end)
      |> Enum.filter(&is_integer/1)

    if ticket_ms != [] do
      bbox(ticket_ms, {full0, full1})
    else
      agent_window(actors, {full0, full1})
    end
  end

  defp agent_window(actors, {full0, full1}) do
    actors
    |> Enum.filter(fn {key, a} -> actor_kind(key, a) == :agent end)
    |> Enum.flat_map(fn {_key, a} -> Map.get(a, :samples, []) end)
    |> Enum.map(&Map.get(&1, :timestamp_ms))
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> {full0, full1}
      list -> bbox(list, {full0, full1})
    end
  end

  defp bbox(ms, {full0, full1}) do
    lo = Enum.min(ms)
    hi = Enum.max(ms)
    pad = max(round((hi - lo) * 0.04), 60_000)
    {max(lo - pad, full0), min(hi + pad, full1)}
  end

  defp full_window(dataset, actors) do
    range = dataset |> Map.get(:provenance, %{}) |> Map.get(:time_range, %{})
    t0 = iso_ms(Map.get(range, :start))
    t1 = iso_ms(Map.get(range, :end))

    if is_integer(t0) and is_integer(t1) and t1 > t0 do
      {t0, t1}
    else
      sample_window(actors)
    end
  end

  defp sample_window(actors) do
    ms =
      actors
      |> Enum.flat_map(fn {_k, a} -> Map.get(a, :samples, []) end)
      |> Enum.map(&Map.get(&1, :timestamp_ms))
      |> Enum.filter(&is_integer/1)

    case ms do
      [] -> {0, 1}
      list -> {Enum.min(list), max(Enum.max(list), Enum.min(list) + 1)}
    end
  end

  # ---- helpers ----

  defp actor_kind(key, actor) do
    case Map.get(actor, :samples, []) |> List.first() |> kv(:actor_type) do
      "daemon" -> :daemon
      "operator" -> :operator
      "executor" -> :operator
      _other -> kind_from_key(key)
    end
  end

  defp kind_from_key("_daemon"), do: :daemon
  defp kind_from_key("_operator"), do: :operator
  defp kind_from_key(_key), do: :agent

  defp actor_label("_operator"), do: "Executor"
  defp actor_label("_daemon"), do: "Daemon"
  defp actor_label("ticket:" <> number), do: "#" <> number
  defp actor_label(key) when is_binary(key), do: key
  defp actor_label(key), do: to_string(key)

  defp kv(nil, _key), do: nil
  defp kv(map, key) when is_map(map), do: Map.get(map, key)

  defp iso_ms(nil), do: nil

  defp iso_ms(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp iso_ms(_other), do: nil

  defp num(v) when is_number(v), do: v * 1.0
  defp num(_v), do: nil

  defp bool01(nil), do: 0
  defp bool01(_v), do: 1

  defp mean(_sum, 0), do: 0.0
  defp mean(sum, n), do: sum / n

  defp pct(_num, 0), do: 0
  defp pct(num, denom), do: round(num / denom * 100)

  defp round1(v) when is_number(v), do: Float.round(v * 1.0, 1)
  defp round1(_v), do: 0.0

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp runtime_opts(opts) do
    opts
    |> Keyword.put_new(:cap, safe_cap())
    |> Keyword.put_new(:cores, System.schedulers_online())
    |> Keyword.put_new(:host_mem_bytes, host_mem_bytes())
    |> Keyword.put_new(:buckets, @default_buckets)
  end

  defp safe_cap do
    Aiur.Config.max_concurrent_agents()
  rescue
    _ -> @default_cap
  catch
    _, _ -> @default_cap
  end

  defp host_mem_bytes do
    case File.read("/proc/meminfo") do
      {:ok, content} -> meminfo_total(content)
      _ -> @default_host_mem_bytes
    end
  rescue
    _ -> @default_host_mem_bytes
  end

  defp meminfo_total(content) do
    case Regex.run(~r/MemTotal:\s+(\d+)\s*kB/, content) do
      [_, kb] -> String.to_integer(kb) * 1024
      _ -> @default_host_mem_bytes
    end
  end
end
