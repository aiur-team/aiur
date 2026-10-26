defmodule AiurWeb.OperatorControlCenter.Analytics.Pressure do
  @moduledoc false

  alias Aiur.RunTelemetry.Timeline
  alias AiurWeb.OperatorControlCenter.Analytics.ProjectedSeries

  # ---- per-actor summary ----

  @doc false
  @spec actor_summary(String.t(), map()) :: map()
  def actor_summary(key, actor) do
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

  @doc false
  @spec bucket_actor([map()], map(), number(), number(), pos_integer()) :: map()
  def bucket_actor(samples, timeline, axis0, bw, buckets) do
    samples
    |> Enum.reduce(%{}, fn s, acc -> accumulate_sample(acc, s, timeline, axis0, bw, buckets) end)
    |> Map.new(fn {b, {cs, cn, rs, rn}} -> {b, %{cpu: mean(cs, cn), rss: mean(rs, rn)}} end)
    |> ProjectedSeries.fill(samples, fn ts -> bucket_index(Timeline.project(timeline, ts), axis0, bw, buckets) end)
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

  @doc false
  @spec bucket_pressure([map()], map(), number(), number(), pos_integer()) :: map()
  def bucket_pressure(samples, timeline, axis0, bw, buckets) do
    Enum.reduce(samples, %{}, fn sample, acc ->
      case Map.get(sample, :timestamp_ms) do
        ts when is_integer(ts) ->
          index = bucket_index(Timeline.project(timeline, ts), axis0, bw, buckets)
          Map.update(acc, index, pressure_cell(sample), &merge_pressure_cell(&1, sample))

        _other ->
          acc
      end
    end)
  end

  defp pressure_cell(sample), do: merge_pressure_cell(%{}, sample)

  defp merge_pressure_cell(cell, sample) do
    fleet_status = field(sample, :fleet_capacity_status)
    build_status = field(sample, :build_gate_status)
    ts = Map.get(sample, :timestamp_ms, 0)

    cell
    |> put_latest_state(:fleet_capacity_status, :fleet_state_ts, fleet_status, ts)
    |> put_latest_state(:build_gate_status, :build_state_ts, build_status, ts)
    |> put_latest_state(:fleet_admission_signal, :fleet_signal_ts, field(sample, :fleet_admission_signal), ts)
    |> put_latest_observation(:fleet_capacity_observed_at_ms, :fleet_observed_ts, field(sample, :fleet_capacity_observed_at_ms), ts)
    |> put_latest_observation(:build_gate_observed_at_ms, :build_observed_ts, field(sample, :build_gate_observed_at_ms), ts)
    |> then(fn acc ->
      if fleet_status == "current" do
        acc
        |> put_max(:fleet_agents_occupied, field(sample, :fleet_agents_occupied))
        |> put_latest_metrics(ts,
          fleet_agents_configured: field(sample, :fleet_agents_configured),
          fleet_agents_max: field(sample, :fleet_agents_max),
          fleet_agents_effective: field(sample, :fleet_agents_effective),
          fleet_load: field(sample, :fleet_load),
          fleet_load_threshold: field(sample, :fleet_load_threshold),
          fleet_schedulers: field(sample, :fleet_schedulers)
        )
      else
        acc
      end
    end)
    |> then(fn acc ->
      if build_status in ["measured", "disabled", "partial"] do
        acc
        |> put_max(:build_gate_active, field(sample, :build_gate_active))
        |> put_max(:build_gate_queued, field(sample, :build_gate_queued))
        |> put_max(:build_queue_oldest_wait_seconds, field(sample, :build_queue_oldest_wait_seconds))
        |> put_min_max(:build_gate_capacity, field(sample, :build_gate_capacity))
        |> put_latest_metrics(ts, build_gate_capacity: field(sample, :build_gate_capacity))
      else
        acc
      end
    end)
  end

  defp put_latest_state(cell, _key, _ts_key, nil, _ts), do: cell

  defp put_latest_state(cell, key, ts_key, value, ts) do
    if ts >= Map.get(cell, ts_key, -1), do: cell |> Map.put(key, value) |> Map.put(ts_key, ts), else: cell
  end

  defp put_latest_observation(cell, key, ts_key, value, ts) do
    if ts >= Map.get(cell, ts_key, -1) do
      cell
      |> Map.put(key, if(is_number(value), do: value, else: nil))
      |> Map.put(ts_key, ts)
    else
      cell
    end
  end

  defp put_latest_metrics(cell, ts, metrics) do
    if ts >= Map.get(cell, :metric_ts, -1) do
      metrics
      |> Enum.reduce(Map.put(cell, :metric_ts, ts), &put_numeric_metric/2)
    else
      cell
    end
  end

  defp put_numeric_metric({key, value}, cell), do: Map.put(cell, key, if(is_number(value), do: value, else: nil))

  defp put_max(cell, _key, value) when not is_number(value), do: cell
  defp put_max(cell, key, value), do: Map.update(cell, key, value, &max(&1, value))

  # Tracks both edges of a capacity that changes mid-run so a peak can never be
  # presented beside a single "latest" capacity it may not have occurred under.
  defp put_min_max(cell, _key, value) when not is_number(value), do: cell

  defp put_min_max(cell, key, value) do
    cell
    |> Map.update({key, :min}, value, &min(&1, value))
    |> Map.update({key, :max}, value, &max(&1, value))
  end

  defp field(sample, key), do: Map.get(sample, key, Map.get(sample, Atom.to_string(key)))

  @doc false
  @spec build_series(map(), map(), [map()], MapSet.t(), number(), number(), pos_integer()) :: [map()]
  def build_series(bucketed, pressure_buckets, display, display_keys, t0, bw, buckets) do
    for b <- 0..(buckets - 1) do
      bucketed
      |> Enum.reduce({0.0, 0.0, 0.0, 0.0, 0, %{}}, &fold_cell(&1, &2, b, display_keys))
      |> series_bucket(b, t0, bw, display)
      |> Map.merge(pressure_bucket(Map.get(pressure_buckets, b)))
    end
  end

  defp pressure_bucket(nil), do: %{pressure_state: :empty}

  defp pressure_bucket(cell) do
    fleet = Map.get(cell, :fleet_capacity_status)
    build = Map.get(cell, :build_gate_status)

    state =
      cond do
        fleet == "stale" -> :stale_fleet
        build == "degraded" -> :degraded_build
        build == "partial" or fleet != "current" or build not in ["measured", "disabled"] -> :partial
        true -> :measured
      end

    cell
    |> Map.drop([:metric_ts, :fleet_state_ts, :build_state_ts, :fleet_observed_ts, :build_observed_ts])
    |> drop_unavailable_fleet(fleet)
    |> drop_unavailable_build(build)
    |> Map.put(:pressure_state, state)
  end

  defp drop_unavailable_fleet(cell, "current"), do: cell

  defp drop_unavailable_fleet(cell, _status),
    do:
      Map.drop(cell, [
        :fleet_agents_occupied,
        :fleet_agents_configured,
        :fleet_agents_max,
        :fleet_agents_effective,
        :fleet_load,
        :fleet_load_threshold,
        :fleet_schedulers,
        :fleet_admission_signal
      ])

  defp drop_unavailable_build(cell, status) when status in ["measured", "disabled", "partial"], do: cell

  defp drop_unavailable_build(cell, _status),
    do: Map.drop(cell, [:build_gate_capacity, :build_gate_active, :build_gate_queued, :build_queue_oldest_wait_seconds])

  @doc false
  @spec pressure_summary([map()]) :: map()
  def pressure_summary(series) do
    %{
      peak_occupied: max_value(series, :fleet_agents_occupied),
      peak_active_builds: max_value(series, :build_gate_active),
      peak_queued_builds: max_value(series, :build_gate_queued),
      longest_wait_seconds: max_value(series, :build_queue_oldest_wait_seconds),
      latest_configured_capacity: latest_source_value(series, :fleet_capacity_status, ["current"], :fleet_agents_configured),
      latest_max_capacity: latest_source_value(series, :fleet_capacity_status, ["current"], :fleet_agents_max),
      latest_effective_capacity: latest_source_value(series, :fleet_capacity_status, ["current"], :fleet_agents_effective),
      latest_admission_signal: latest_source_value(series, :fleet_capacity_status, ["current"], :fleet_admission_signal),
      latest_load: latest_value(series, :fleet_load),
      latest_load_threshold: latest_value(series, :fleet_load_threshold),
      latest_schedulers: latest_value(series, :fleet_schedulers),
      latest_build_capacity: latest_source_value(series, :build_gate_status, ["measured", "disabled", "partial"], :build_gate_capacity),
      min_build_capacity: series_min_value(series, :build_gate_capacity),
      max_build_capacity: series_max_value(series, :build_gate_capacity),
      latest_fleet_observed_at_ms: latest_source_value(series, :fleet_capacity_status, ["current"], :fleet_capacity_observed_at_ms),
      latest_build_observed_at_ms:
        latest_source_value(
          series,
          :build_gate_status,
          ["measured", "disabled", "partial"],
          :build_gate_observed_at_ms
        )
    }
  end

  defp latest_source_value(series, status_key, valid_statuses, value_key) do
    sample = Enum.find(Enum.reverse(series), &(Map.get(&1, status_key) != nil))
    if sample && Map.get(sample, status_key) in valid_statuses, do: Map.get(sample, value_key)
  end

  defp latest_value(series, key), do: series |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_number/1) |> List.last()

  defp max_value(series, key) do
    values = series |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_number/1)
    Enum.max(values, fn -> nil end)
  end

  defp series_min_value(series, key) do
    values = series |> Enum.map(&Map.get(&1, {key, :min})) |> Enum.filter(&is_number/1)
    Enum.min(values, fn -> nil end)
  end

  defp series_max_value(series, key) do
    values = series |> Enum.map(&Map.get(&1, {key, :max})) |> Enum.filter(&is_number/1)
    Enum.max(values, fn -> nil end)
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

  # ---- window + axis ----

  # The axis the model is drawn on. `:absolute` keeps wall-clock milliseconds,
  # which is right for one continuous session. `:active` elides the idle
  # stretches between sessions so a multi-week Build Order is charted over the
  # hours it was actually running.
  @doc false
  @spec timeline(map(), map(), {integer(), integer()}, keyword()) :: map()
  def timeline(dataset, actors, window, opts) do
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

  @doc false
  @spec window(map(), map(), keyword()) :: {integer(), integer()}
  def window(dataset, actors, opts) do
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

  @doc false
  @spec actor_kind(term(), map()) :: atom()
  def actor_kind(key, actor) do
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

  defp round1(v) when is_number(v), do: Float.round(v * 1.0, 1)
  defp round1(_v), do: 0.0

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
