defmodule AiurWeb.OperatorControlCenter.Analytics.Presenter do
  @moduledoc """
  Reshapes the durable `Aiur.RunTelemetry` dataset into the analytics view
  model: a bucketed per-actor resource series, run KPIs, and per-ticket
  lifecycle rows. Pure `model/2` is driven by an already-built dataset so it is
  unit-testable against a fixture; `load/1` resolves the live telemetry file,
  concurrency cap, core count, and host memory before delegating to it.
  """

  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Dataset

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
          kpis: map()
        }

  @doc "Loads the live run telemetry and builds the analytics model, or reports why it is unavailable."
  @spec load(keyword()) :: {:ok, model()} | {:unavailable, atom()}
  def load(opts \\ []) do
    file = Keyword.get(opts, :telemetry_file) || RunTelemetry.telemetry_file()

    case Dataset.build(file) do
      {:ok, dataset} -> {:ok, model(dataset, runtime_opts(opts))}
      {:error, {:no_telemetry_files, _paths}} -> {:unavailable, :no_telemetry}
      {:error, _reason} -> {:unavailable, :error}
    end
  rescue
    _error -> {:unavailable, :error}
  end

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
    bw = max((t1 - t0) / buckets, 1)

    summaries = actors |> Enum.map(fn {key, a} -> actor_summary(key, a) end) |> Enum.sort_by(& &1.cpu_seconds, :desc)

    display =
      summaries
      |> Enum.filter(&(&1.kind == :agent and &1.cpu_seconds > 0))
      |> Enum.take(@max_series_actors)
      |> Enum.with_index(1)
      |> Enum.map(fn {actor, i} -> Map.put(actor, :color_i, i) end)

    display_keys = MapSet.new(display, & &1.key)

    bucketed = Map.new(actors, fn {key, a} -> {key, {actor_kind(key, a), bucket_actor(Map.get(a, :samples, []), t0, bw, buckets)}} end)
    series = build_series(bucketed, display, display_keys, t0, bw, buckets)
    kpis = compute_kpis(series, tickets, cap, cores, host_mem, bw)
    rows = tickets |> Enum.map(fn {id, t} -> ticket_row(id, t) end) |> Enum.reject(&is_nil/1) |> Enum.sort_by(& &1.start_ms)

    %{
      available?: true,
      window: %{start_ms: t0, end_ms: t1, buckets: buckets},
      cap: cap,
      cores: cores,
      cpu_ceiling: cores * 100,
      host_mem_bytes: host_mem,
      actors: display,
      series: series,
      tickets: rows,
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

  defp bucket_actor(samples, t0, bw, buckets) do
    samples
    |> Enum.reduce(%{}, fn s, acc -> accumulate_sample(acc, s, t0, bw, buckets) end)
    |> Map.new(fn {b, {cs, cn, rs, rn}} -> {b, %{cpu: mean(cs, cn), rss: mean(rs, rn)}} end)
  end

  defp accumulate_sample(acc, sample, t0, bw, buckets) do
    ts = Map.get(sample, :timestamp_ms)

    if is_integer(ts) and Map.get(sample, :availability) == "measured" do
      add_cell(acc, bucket_index(ts, t0, bw, buckets), num(Map.get(sample, "cpu_percent")), num(Map.get(sample, "rss_bytes")))
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

  defp compute_kpis(series, tickets, cap, cores, host_mem, bw) do
    ceiling = cores * 100
    concs = Enum.map(series, & &1.conc)
    peak_conc = Enum.max([0 | concs])
    conc_now = List.last(concs) || 0
    mean_cpu = mean(Enum.sum(Enum.map(series, & &1.total_cpu)), length(series))
    mem_now = (List.last(series) || %{}) |> Map.get(:total_mem, 0)
    bucket_hours = bw / 1000 / 3600
    wasted = series |> Enum.reduce(0.0, fn s, acc -> acc + max(cap - s.conc, 0) * bucket_hours end)
    merged = Enum.count(tickets, fn {_id, t} -> merged?(t) end)
    total = map_size(tickets)

    %{
      peak_conc: peak_conc,
      conc_now: conc_now,
      cap: cap,
      mean_util_pct: pct(mean_cpu, ceiling),
      mem_headroom_pct: max(round((1 - mem_now / max(host_mem, 1)) * 100), 0),
      mem_now_bytes: mem_now,
      merged: merged,
      done: merged,
      total: total,
      done_pct: pct(merged, total),
      wasted_slot_hours: round1(wasted)
    }
  end

  # ---- ticket lifecycle rows ----

  defp ticket_row(id, ticket) do
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

      %{
        id: id,
        start_ms: start_ms,
        work_ms: work_ms,
        end_ms: end_ms,
        merged_at: merged_at,
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

  defp phase_start(intervals, phases) do
    intervals
    |> Enum.filter(&(Map.get(&1, :phase) in phases and is_integer(Map.get(&1, :start_ms))))
    |> Enum.map(&Map.get(&1, :start_ms))
    |> case do
      [] -> nil
      list -> Enum.min(list)
    end
  end

  # ---- window ----

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
    case Aiur.Config.settings() do
      {:ok, settings} -> Map.get(settings.agent, :max_concurrent_agents) || @default_cap
      _ -> @default_cap
    end
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
