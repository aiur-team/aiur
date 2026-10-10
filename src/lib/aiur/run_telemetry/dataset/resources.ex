defmodule Aiur.RunTelemetry.Dataset.Resources do
  @moduledoc "Per-actor resource sample statistics, gaps, and availability for `Aiur.RunTelemetry.Dataset`."

  @resource_metrics ~w(
    cpu_percent rss_bytes fd_count read_bytes write_bytes
    read_bytes_per_second write_bytes_per_second
    system_fd_used system_fd_limit system_fd_available system_fd_headroom_ratio
    fleet_agents_occupied fleet_agents_configured fleet_agents_max fleet_agents_effective
    fleet_load fleet_load_threshold fleet_schedulers
    build_gate_capacity build_gate_active build_gate_queued build_queue_oldest_wait_seconds
  )
  @resource_evidence ~w(
    fleet_capacity_status fleet_capacity_age_ms fleet_capacity_observed_at_ms
    fleet_admission_signal
    build_gate_enabled build_gate_status build_gate_observed_at_ms
  )a
  @default_sample_interval_ms 5_000
  @default_gap_threshold_multiplier 1.5

  @doc false
  @spec reduce_actors([map()], keyword()) :: {map(), [map()]}
  def reduce_actors(records, opts) do
    resources = Enum.filter(records, &(&1.kind == "resource"))

    {valid, warnings} =
      Enum.reduce(resources, {[], []}, fn record, {valid, warnings} ->
        case Map.get(record.attributes, "actor") do
          actor when is_binary(actor) and actor != "" ->
            {[record | valid], warnings}

          _other ->
            {valid, [%{type: :resource_actor_missing, record_id: record.record_id} | warnings]}
        end
      end)

    actors =
      valid
      |> Enum.reverse()
      |> Enum.group_by(&Map.fetch!(&1.attributes, "actor"))
      |> Map.new(fn {actor, actor_records} ->
        samples = Enum.map(actor_records, &resource_sample/1)

        {actor,
         %{
           actor: actor,
           actor_type: actor_records |> List.first() |> then(&Map.get(&1.attributes, "actor_type")),
           samples: samples,
           profile: resource_profile(samples),
           gaps: resource_gaps(samples, opts),
           availability: availability_counts(samples)
         }}
      end)

    {actors, Enum.reverse(warnings)}
  end

  defp resource_sample(record) do
    metrics =
      @resource_metrics
      |> Map.new(fn metric -> {metric, resource_metric(record.attributes, metric)} end)

    evidence =
      @resource_evidence
      |> Map.new(fn field -> {field, Map.get(record.attributes, Atom.to_string(field))} end)

    metrics
    |> Map.merge(evidence)
    |> Map.merge(%{
      actor: record.attributes["actor"],
      actor_type: record.attributes["actor_type"],
      ticket: record.attributes["ticket"],
      availability: record.attributes["availability"] || "unavailable",
      unavailable_reason: record.attributes["unavailable_reason"],
      process_count: record.attributes["process_count"],
      partial_fields: record.attributes["partial_fields"] || [],
      timestamp: record.timestamp_iso,
      timestamp_ms: record.timestamp_ms,
      boot_id: record.boot_id,
      record_id: record.record_id
    })
  end

  defp resource_metric(attributes, "system_fd_used"),
    do: get_in(attributes, ["system_fd", "used"])

  defp resource_metric(attributes, "system_fd_limit"),
    do: get_in(attributes, ["system_fd", "limit"])

  defp resource_metric(attributes, "system_fd_available"),
    do: get_in(attributes, ["system_fd", "available"])

  defp resource_metric(attributes, "system_fd_headroom_ratio"),
    do: get_in(attributes, ["system_fd", "headroom_ratio"])

  defp resource_metric(attributes, metric), do: Map.get(attributes, metric)

  @doc false
  @spec resource_profile([map()]) :: map()
  def resource_profile(samples) do
    @resource_metrics
    |> Enum.flat_map(fn metric ->
      values = samples |> Enum.map(&Map.get(&1, metric)) |> Enum.filter(&is_number/1)
      if values == [], do: [], else: [{metric, statistics(values)}]
    end)
    |> Map.new()
  end

  defp statistics(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      count: count,
      min: hd(sorted),
      mean: Enum.sum(sorted) / count,
      median: percentile(sorted, 0.5, :interpolate),
      p95: percentile(sorted, 0.95, :nearest_rank),
      max: List.last(sorted)
    }
  end

  defp percentile(sorted, percentile, :nearest_rank) do
    index = max(ceil(percentile * length(sorted)) - 1, 0)
    Enum.at(sorted, index)
  end

  defp percentile(sorted, 0.5, :interpolate) do
    count = length(sorted)
    midpoint = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, midpoint)
    else
      (Enum.at(sorted, midpoint - 1) + Enum.at(sorted, midpoint)) / 2
    end
  end

  @doc false
  @spec resource_gaps([map()], keyword()) :: [map()]
  def resource_gaps(samples, opts) do
    interval_ms = Keyword.get(opts, :sample_interval_ms, @default_sample_interval_ms)

    threshold_ms =
      Keyword.get(
        opts,
        :sample_gap_threshold_ms,
        round(interval_ms * @default_gap_threshold_multiplier)
      )

    samples
    |> Enum.group_by(& &1.boot_id)
    |> Enum.flat_map(fn {boot_id, boot_samples} ->
      boot_samples
      |> Enum.sort_by(& &1.timestamp_ms)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(&resource_gap(&1, boot_id, interval_ms, threshold_ms))
    end)
    |> Enum.sort_by(&{&1.start_at, &1.boot_id})
  end

  defp resource_gap([previous, current], boot_id, interval_ms, threshold_ms) do
    duration_ms = current.timestamp_ms - previous.timestamp_ms

    if duration_ms > threshold_ms do
      [
        %{
          boot_id: boot_id,
          start_at: previous.timestamp,
          end_at: current.timestamp,
          duration_ms: duration_ms,
          expected_interval_ms: interval_ms
        }
      ]
    else
      []
    end
  end

  @doc false
  @spec availability_counts([map()]) :: %{measured: non_neg_integer(), unavailable: non_neg_integer()}
  def availability_counts(samples) do
    Enum.reduce(samples, %{measured: 0, unavailable: 0}, fn sample, counts ->
      key = if sample.availability == "measured", do: :measured, else: :unavailable
      Map.update!(counts, key, &(&1 + 1))
    end)
  end
end
