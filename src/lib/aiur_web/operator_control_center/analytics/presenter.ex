defmodule AiurWeb.OperatorControlCenter.Analytics.Presenter do
  @moduledoc """
  Reshapes the durable `Aiur.RunTelemetry` dataset into the analytics view
  model: a bucketed per-actor resource series, run KPIs, and per-ticket
  lifecycle rows plus a dispatch-time complexity breakdown. Pure `model/2` is driven by an already-built dataset so it is
  unit-testable against a fixture; `load/1` resolves the live telemetry file,
  concurrency cap, core count, and host memory before delegating to it.

  The same model serves two scopes. The latest-run view passes
  `session: :current` and gets absolute timestamps over one daemon boot. It
  prefers the live boot, then falls back to the newest materialized prior boot
  when a restart has moved the daemon to a fresh log root. The
  Build Order view passes the selected member ticket set, `session: :current`,
  and `timeline: :active`. That keeps its recurring refresh a bounded tail read;
  cross-session reporting belongs to a materialized summary rather than a live
  full-stream parse. Both feed the same `Charts`, whose axis already labels ticks
  as elapsed time.
  """

  alias Aiur.{Orchestrator, RunTelemetry}
  alias Aiur.Orchestrator.CapacityBinding
  alias Aiur.RunTelemetry.{Dataset, Summaries, Timeline}
  alias AiurWeb.OperatorControlCenter.Analytics.LatestRun

  @default_buckets 180
  @max_series_actors 8
  @default_host_mem_bytes 32 * 1024 * 1024 * 1024
  @default_cap 10

  @type model :: %{
          available?: boolean(),
          window: %{start_ms: integer(), end_ms: integer(), buckets: pos_integer()},
          source_boot_id: String.t() | nil,
          source_observed_at: String.t() | nil,
          cap: non_neg_integer(),
          cap_available?: boolean(),
          configured_cap: non_neg_integer() | nil,
          session_cap: non_neg_integer() | nil,
          cap_binding: String.t() | nil,
          cap_staleness: {:stale | :retained, non_neg_integer()} | nil,
          cores: pos_integer(),
          cpu_ceiling: number(),
          host_mem_bytes: number(),
          actors: [map()],
          series: [map()],
          pressure: map(),
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

  Unavailable reasons distinguish an idle fleet from a persistence failure:
  `:no_telemetry` means nothing analyzable was recorded, while
  `:retained_unreadable` means retained run summaries exist but could not be
  decoded, and `:error` is an unexpected analysis failure.
  """
  @spec load(keyword()) :: {:ok, model()} | {:unavailable, atom()}
  def load(opts \\ []) do
    file = Keyword.get(opts, :telemetry_file) || RunTelemetry.telemetry_file()
    analyzable? = fn dataset -> dataset |> scope(opts) |> dataset_analyzable?() end

    result =
      case Keyword.get(opts, :session, :all) do
        :current ->
          LatestRun.load(file, current_boot_id(), analyzable?)

        :cross ->
          cross_session(file)

        _other ->
          Dataset.build(file, [])
      end

    case result do
      {:ok, dataset} ->
        dataset |> scope(opts) |> analyzable(opts)

      {:error, {:no_telemetry_files, _paths}} ->
        {:unavailable, :no_telemetry}

      {:error, :retained_unreadable} ->
        {:unavailable, :retained_unreadable}
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

  # `Dataset.merge/1` already unions provenance across the merged boots; only the
  # producer label differs, so name this path rather than recomputing the union.
  defp merge_datasets(datasets) do
    merged = Dataset.merge(datasets)
    Map.update!(merged, :provenance, &Map.put(&1, :generated_by, "presenter:cross"))
  end

  # A readable stream that contains nothing for this scope is "no telemetry", not
  # a zero-cost build: rendering empty charts and zeroed KPIs would claim a build
  # burned nothing when in truth none of its members has run yet.
  defp analyzable(dataset, opts) do
    if dataset_analyzable?(dataset) do
      {:ok, model(dataset, runtime_opts(opts))}
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
    cap_available? = Keyword.get(opts, :cap_available?, true)
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

    series = build_series(bucketed, pressure_buckets, display, display_keys, axis0, bw, buckets)

    kpis =
      compute_kpis(
        series,
        tickets,
        %{cap: cap, cap_available?: cap_available?, cores: cores, host_mem: host_mem, bw: bw, dataset: dataset},
        opts
      )

    complexity_breakdown = complexity_breakdown(tickets)

    rows =
      tickets
      |> Enum.map(fn {id, t} -> ticket_row(id, t, timeline) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.start_ms)

    %{
      available?: true,
      window: %{start_ms: axis0, end_ms: axis1, buckets: buckets},
      source_boot_id: single_boot_id(dataset),
      source_observed_at: get_in(dataset, [:provenance, :time_range, :end]),
      cap: cap,
      cap_available?: cap_available?,
      configured_cap: configured_cap,
      session_cap: session_cap,
      cap_binding: cap_binding,
      cap_staleness: cap_staleness,
      cores: cores,
      cpu_ceiling: cores * 100,
      host_mem_bytes: host_mem,
      actors: display,
      series: series,
      pressure: pressure_summary(series),
      tickets: rows,
      complexity_breakdown: complexity_breakdown,
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
  def cap_label(%{} = model) do
    head =
      case model do
        %{cap_available?: false} -> "unknown cap"
        %{cap: cap} -> "#{cap} cap"
      end

    head <> annotations(model)
  end

  @doc """
  Renders idle slot-hours, or an em dash when no effective cap was reported.

  Kept beside `cap_label/1` so every surface spells the unknown the same way:
  the figure is a subtraction from the cap, so an unknown cap has no figure.
  """
  @spec wasted_slot_hours_label(number() | nil) :: String.t()
  def wasted_slot_hours_label(hours) when is_number(hours), do: "#{hours}h"
  def wasted_slot_hours_label(_hours), do: "—"

  defp annotations(model) do
    case Enum.reject([binding_note(model), ceiling_note(model), age_note(model)], &is_nil/1) do
      [] -> ""
      notes -> " (" <> Enum.join(notes, ", ") <> ")"
    end
  end

  defp binding_note(model) do
    case Map.get(model, :cap_binding) do
      binding when is_binary(binding) -> "binding: #{binding}"
      _absent -> nil
    end
  end

  # The configured value is always shown when the effective cap is unknown: it
  # is the only ceiling left to report, and its absence is what would make the
  # "unknown" unactionable.
  defp ceiling_note(%{cap_available?: false, configured_cap: configured}) when is_integer(configured),
    do: "configured #{configured}"

  defp ceiling_note(%{cap_available?: false}), do: nil

  defp ceiling_note(%{cap: cap} = model) do
    session = Map.get(model, :session_cap, cap)
    configured = Map.get(model, :configured_cap, cap)

    [{"session", session}, {"configured", configured}]
    |> Enum.filter(fn {_name, value} -> is_integer(value) and value != cap end)
    # One number, one name. When the session ceiling and the configured value
    # coincide, "configured" is the one an operator can go and change.
    |> Enum.reverse()
    |> Enum.uniq_by(fn {_name, value} -> value end)
    |> Enum.reverse()
    |> case do
      [] -> nil
      pairs -> Enum.map_join(pairs, ", ", fn {name, value} -> "#{name} #{value}" end)
    end
  end

  # `cap_staleness` is populated only for a degraded read, so its mere presence
  # is the signal. A current reading carries no note at all.
  defp age_note(model) do
    case Map.get(model, :cap_staleness) do
      {:retained, age_ms} -> "retained, daemon unreachable#{age_suffix(age_ms)}"
      {:stale, age_ms} -> "stale#{age_suffix(age_ms)}"
      _absent -> nil
    end
  end

  # Under a second the age says nothing an operator can act on, and printing
  # "0s old" beside "stale" reads as a contradiction rather than a warning.
  defp age_suffix(age_ms) when is_integer(age_ms) and age_ms >= 1_000, do: ", #{humanize_age(age_ms)} old"
  defp age_suffix(_age_ms), do: ""

  defp humanize_age(age_ms) do
    seconds = div(age_ms, 1_000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      true -> "#{Float.round(seconds / 3_600, 1)}h"
    end
  end

  # Idle slot-hours are measured against the ceiling that actually existed —
  # the effective cap — not the configured one, so the figure counts slots the
  # dispatcher could have filled rather than slots that were never on offer.
  #
  # With no known ceiling there is no subtrahend, so there is no figure. `nil`
  # renders as an em dash: an unknown cap must not produce a precise-looking
  # hour count derived from a number the page just admitted it does not have.
  defp wasted_slot_hours(_series, %{cap_available?: false}, _bucket_hours), do: nil

  defp wasted_slot_hours(series, ctx, bucket_hours) do
    series
    |> Enum.reduce(0.0, fn s, acc -> acc + max(ctx.cap - s.conc, 0) * bucket_hours end)
    |> round1()
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

  defp bucket_pressure(samples, timeline, axis0, bw, buckets) do
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

  defp build_series(bucketed, pressure_buckets, display, display_keys, t0, bw, buckets) do
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
      latest_configured_capacity: latest_value(series, :fleet_agents_configured),
      latest_max_capacity: latest_value(series, :fleet_agents_max),
      latest_effective_capacity: latest_value(series, :fleet_agents_effective),
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
    case Enum.find(Enum.reverse(series), &(Map.get(&1, status_key) in valid_statuses)) do
      nil -> nil
      sample -> Map.get(sample, value_key)
    end
  end

  defp latest_value(series, key) do
    series |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_number/1) |> List.last()
  end

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

  # ---- KPIs ----

  defp compute_kpis(series, tickets, ctx, opts) do
    ceiling = ctx.cores * 100
    concs = Enum.map(series, & &1.conc)
    peak_conc = Enum.max([0 | concs])
    conc_now = List.last(concs) || 0
    mean_cpu = mean(Enum.sum(Enum.map(series, & &1.total_cpu)), length(series))
    mem_now = (List.last(series) || %{}) |> Map.get(:total_mem, 0)
    bucket_hours = ctx.bw / 1000 / 3600
    wasted = wasted_slot_hours(series, ctx, bucket_hours)
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
    |> Keyword.merge(runtime_caps(opts), fn _key, given, _derived -> given end)
    |> Keyword.put_new(:cores, System.schedulers_online())
    |> Keyword.put_new(:host_mem_bytes, host_mem_bytes())
    |> Keyword.put_new(:buckets, @default_buckets)
  end

  defp runtime_caps(opts) do
    if Keyword.has_key?(opts, :cap) do
      []
    else
      opts |> capacity_reading() |> cap_facts()
    end
  end

  # Every ceiling the daemon reports travels together. Reading only `effective`
  # is what let the page and `aiur status` disagree: the CLI prints the session
  # ceiling, so a page that never mentions it cannot be reconciled with the CLI.
  defp cap_facts({%{effective: effective} = capacity, polling, staleness})
       when is_integer(effective) and effective > 0 do
    [
      cap: effective,
      cap_available?: true,
      session_cap: positive_or(Map.get(capacity, :max), effective),
      configured_cap: positive_or(Map.get(capacity, :configured), effective),
      # The polling report travels from the same snapshot as the capacity, so
      # the page cannot blame "ticket supply" in a state where `aiur status`
      # says "has not polled yet" (#2138). Two surfaces, one classifier, one
      # answer.
      cap_binding: CapacityBinding.short_label(CapacityBinding.binding(capacity, polling)),
      cap_staleness: staleness
    ]
  end

  # No effective fact means no ceiling is known. The local config file is NOT
  # substituted here: this process may not run on the daemon's host, so its
  # `.aiur/config` is a different fact wearing the same name, and reporting it
  # as "configured" would put a confident number under an admitted unknown.
  defp cap_facts(_reading) do
    [cap: safe_cap(), cap_available?: false, configured_cap: nil, session_cap: nil, cap_binding: nil, cap_staleness: nil]
  end

  defp positive_or(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_or(_value, fallback), do: fallback

  # A retained-but-aged snapshot is still rendered — `SnapshotStore` returns it
  # precisely so callers can show last-known-good data — but its age comes back
  # with it and is never discarded. Dropping `freshness` here is what turned an
  # hours-old cap into an unmarked current one.
  defp capacity_reading(opts) do
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
    timeout = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

    case Orchestrator.dashboard_snapshot(orchestrator, timeout) do
      {:current, %{capacity: %{} = capacity} = snapshot, _freshness} ->
        {capacity, snapshot_polling(snapshot), nil}

      {:stale, %{capacity: %{} = capacity} = snapshot, freshness} ->
        {capacity, snapshot_polling(snapshot), staleness(freshness)}

      _other ->
        :unavailable
    end
  end

  defp snapshot_polling(%{polling: %{} = polling}), do: polling
  defp snapshot_polling(_snapshot), do: %{}

  # The two degraded states must not collapse into one message. An aged reading
  # from a live daemon is a cap that may have moved since; a retained reading
  # from a daemon that is no longer there is a cap nobody is enforcing.
  defp staleness(%{reason: :orchestrator_unavailable} = freshness),
    do: {:retained, freshness_age_ms(freshness)}

  defp staleness(freshness), do: {:stale, freshness_age_ms(freshness)}

  defp freshness_age_ms(%{age_ms: age_ms}) when is_integer(age_ms) and age_ms >= 0, do: age_ms
  defp freshness_age_ms(_freshness), do: 0

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
