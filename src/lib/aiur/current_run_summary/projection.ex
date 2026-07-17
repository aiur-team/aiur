defmodule Aiur.CurrentRunSummary.Projection do
  @moduledoc false

  alias AiurWeb.OperatorControlCenter.UnitsPolicy

  @nonterminal_lifecycles [
    :queued,
    :retrying,
    :allocated,
    :running,
    :paused,
    :waiting,
    :replaced
  ]
  @cancelled_states ~w(cancelled canceled not_planned notplanned)

  @spec snapshot(map()) :: map()
  def snapshot(inputs) when is_map(inputs) do
    units = map_value(inputs, :units)
    rows = units |> map_value(:rows, []) |> List.wrap() |> Enum.filter(&is_map/1)
    run = normalize_run(map_value(inputs, :run))
    members = Enum.map(rows, &member_fact/1)
    counts = counts(rows, members)
    weights = weights(members)
    source_health = source_health(units)
    membership_freshness = units |> map_value(:freshness) |> map_value(:membership) |> freshness_status()
    truncated? = map_value(units, :truncated?, false) == true
    weight_health = inputs |> map_value(:weight_health, :healthy) |> health_status()

    progress =
      progress(
        members,
        weights,
        run,
        source_health.membership,
        membership_freshness,
        truncated?
      )

    denominator_generation = map_value(inputs, :denominator_generation, 0)

    %{
      version: Aiur.CurrentRunSummary.version(),
      generation: map_value(inputs, :generation, 0),
      run: run,
      counts: counts,
      weights: weights,
      progress: progress,
      denominator: %{
        generation: denominator_generation,
        signature: denominator_signature(rows)
      },
      eta:
        eta(
          run,
          counts,
          weights,
          denominator_generation,
          source_health.membership,
          membership_freshness,
          weight_health,
          truncated?
        ),
      health:
        projection_health(
          run,
          source_health,
          membership_freshness,
          weight_health,
          truncated?
        ),
      freshness: projection_freshness(members, units, progress, membership_freshness),
      sources: source_provenance(units, source_health, membership_freshness, weight_health)
    }
  end

  def snapshot(_inputs), do: snapshot(%{})

  @spec denominator_signature([map()]) :: String.t()
  def denominator_signature(rows) when is_list(rows) do
    facts =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row ->
        fact = member_fact(row)
        {identity_key(row), fact.weight, fact.class == :non_work_terminal}
      end)
      |> Enum.sort()

    facts
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def denominator_signature(_rows), do: denominator_signature([])

  defp normalize_run(run) when is_map(run) do
    id = map_value(run, :id)
    started_at = map_value(run, :started_at)
    observed_at = map_value(run, :observed_at)
    elapsed_ms = map_value(run, :elapsed_ms)

    valid? =
      map_value(run, :valid?, true) == true and
        valid_run?(id, started_at, observed_at, elapsed_ms)

    elapsed_ms = if valid_elapsed?(elapsed_ms), do: elapsed_ms

    %{
      id: id,
      started_at: started_at,
      observed_at: observed_at,
      elapsed_wall_ms: elapsed_ms,
      elapsed_wall_seconds: if(is_integer(elapsed_ms), do: div(elapsed_ms, 1_000)),
      valid?: valid?
    }
  end

  defp normalize_run(_run) do
    %{
      id: nil,
      started_at: nil,
      observed_at: nil,
      elapsed_wall_ms: nil,
      elapsed_wall_seconds: nil,
      valid?: false
    }
  end

  defp valid_run?(id, started_at, observed_at, elapsed_ms) do
    valid_run_id?(id) and valid_run_window?(started_at, observed_at) and
      valid_elapsed?(elapsed_ms)
  end

  defp valid_run_id?(id) when is_binary(id), do: String.trim(id) != ""
  defp valid_run_id?(_id), do: false

  defp valid_run_window?(%DateTime{} = started_at, %DateTime{} = observed_at) do
    DateTime.compare(observed_at, started_at) != :lt
  end

  defp valid_run_window?(_started_at, _observed_at), do: false
  defp valid_elapsed?(elapsed_ms), do: is_integer(elapsed_ms) and elapsed_ms >= 0

  defp member_fact(row) do
    {weight, defaulted?} = complexity_weight(Map.get(row, :complexity))
    class = state_class(row)

    %{
      row: row,
      class: class,
      weight: weight,
      defaulted?: defaulted?,
      progress: member_progress(row, class)
    }
  end

  defp complexity_weight(value) when is_integer(value) and value in 1..5,
    do: {value, false}

  defp complexity_weight(_value), do: {1, true}

  defp state_class(row) do
    cond do
      non_work_terminal?(row) -> :non_work_terminal
      row[:terminal?] == true and row[:lifecycle] == :completed -> :successful_terminal
      row[:terminal?] != true and row[:lifecycle] in @nonterminal_lifecycles -> :nonterminal
      true -> :unknown
    end
  end

  defp non_work_terminal?(row) do
    row[:terminal?] == true and
      (row[:lifecycle] == :cancelled or normalize_state(row[:tracker_state]) in @cancelled_states)
  end

  defp normalize_state(state) when is_atom(state), do: state |> Atom.to_string() |> normalize_state()

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
    |> String.replace("_", "")
  end

  defp normalize_state(_state), do: ""

  defp counts(rows, members) do
    %{
      live: Enum.count(rows, &UnitsPolicy.in_scope?(&1, :live)),
      remaining: Enum.count(rows, &UnitsPolicy.in_scope?(&1, :unfinished)),
      successful_terminal: Enum.count(members, &(&1.class == :successful_terminal)),
      non_work_terminal: Enum.count(members, &(&1.class == :non_work_terminal)),
      unknown_state: Enum.count(members, &(&1.class == :unknown)),
      total: length(rows)
    }
  end

  defp weights(members) do
    eligible = Enum.reject(members, &(&1.class == :non_work_terminal))
    successful = Enum.filter(eligible, &(&1.class == :successful_terminal))
    excluded = Enum.filter(members, &(&1.class == :non_work_terminal))
    defaulted = Enum.filter(members, & &1.defaulted?)
    known = Enum.filter(eligible, &match?({:known, _percent}, &1.progress))
    unknown = Enum.reject(eligible, &match?({:known, _percent}, &1.progress))
    eligible_weight = sum_weight(eligible)
    successful_weight = sum_weight(successful)

    %{
      eligible: eligible_weight,
      successful_terminal: successful_weight,
      remaining: eligible_weight - successful_weight,
      excluded: sum_weight(excluded),
      excluded_count: length(excluded),
      defaulted: sum_weight(defaulted),
      defaulted_count: length(defaulted),
      known_progress: sum_weight(known),
      unknown_progress: sum_weight(unknown)
    }
  end

  defp sum_weight(members), do: Enum.reduce(members, 0, &(&2 + &1.weight))

  defp member_progress(_row, :non_work_terminal), do: :excluded
  defp member_progress(_row, :successful_terminal), do: {:known, 100}
  defp member_progress(_row, :unknown), do: {:unknown, :contradictory_state}

  defp member_progress(row, :nonterminal) do
    progress = Map.get(row, :progress)

    cond do
      known_not_started?(row) and unknown_progress?(progress) ->
        {:known, 0}

      known_not_started?(row) and fresh_percent(progress) == 0 ->
        {:known, 0}

      known_not_started?(row) ->
        {:unknown, :contradictory_queued_progress}

      is_integer(fresh_percent(progress)) ->
        {:known, clamp(fresh_percent(progress), 0, 100)}

      stale_progress?(progress) ->
        {:unknown, :stale}

      true ->
        {:unknown, :missing_or_malformed}
    end
  end

  defp known_not_started?(row) do
    row[:terminal?] != true and
      (row[:lifecycle] == :queued or row[:replacement_boundary?] == true) and
      UnitsPolicy.condition?(:queued, row)
  end

  defp unknown_progress?(nil), do: true
  defp unknown_progress?(%{status: :unknown}), do: true
  defp unknown_progress?(_progress), do: false

  defp fresh_percent(%{status: :known, freshness: :fresh, percent: percent})
       when is_integer(percent),
       do: percent

  defp fresh_percent(_progress), do: nil
  defp stale_progress?(%{freshness: :stale}), do: true
  defp stale_progress?(_progress), do: false

  defp progress(
         members,
         weights,
         run,
         membership_health,
         membership_freshness,
         truncated?
       ) do
    weighted_numerator =
      Enum.reduce(members, 0, fn
        %{progress: {:known, percent}, weight: weight}, total -> total + weight * percent
        _member, total -> total
      end)

    denominator = weights.eligible * 100

    exact? =
      run.valid? and weights.eligible > 0 and weights.unknown_progress == 0 and
        not truncated? and membership_health == :healthy and membership_freshness == :fresh

    %{
      scale: 100,
      weighted_numerator: %{value: weighted_numerator, scale: 100},
      denominator_weight: weights.eligible,
      known_weight: weights.known_progress,
      unknown_weight: weights.unknown_progress,
      lower_bound: fraction(weighted_numerator, denominator),
      coverage: fraction(weights.known_progress, weights.eligible),
      exact: if(exact?, do: fraction(weighted_numerator, denominator))
    }
  end

  defp eta(
         run,
         counts,
         weights,
         denominator_generation,
         membership_health,
         membership_freshness,
         weight_health,
         truncated?
       ) do
    base = %{
      formula_version: "completed_weight_rate_v1",
      sample_count: counts.successful_terminal,
      completed_weight: weights.successful_terminal,
      remaining_weight: weights.remaining,
      denominator_generation: denominator_generation,
      observed_at: run.observed_at
    }

    reason =
      eta_unavailable_reason(
        run,
        counts,
        weights,
        membership_health,
        membership_freshness,
        weight_health,
        truncated?
      )

    if reason do
      Map.merge(base, %{
        status: :unavailable,
        reason: reason,
        confidence: :unavailable,
        throughput_weight_per_second: nil,
        duration_seconds: nil
      })
    else
      Map.merge(base, %{
        status: :available,
        reason: nil,
        confidence: :evidence_based,
        throughput_weight_per_second: fraction(weights.successful_terminal, run.elapsed_wall_seconds),
        duration_seconds: fraction(weights.remaining * run.elapsed_wall_seconds, weights.successful_terminal)
      })
    end
  end

  defp eta_unavailable_reason(
         run,
         counts,
         weights,
         membership_health,
         membership_freshness,
         weight_health,
         truncated?
       ) do
    eta_source_reason(
      run,
      membership_health,
      membership_freshness,
      weight_health,
      truncated?
    ) || eta_sample_reason(run, counts, weights)
  end

  defp eta_source_reason(
         run,
         membership_health,
         membership_freshness,
         weight_health,
         truncated?
       ) do
    cond do
      not run.valid? -> :invalid_run_window
      membership_health != :healthy -> :unhealthy_membership
      membership_freshness != :fresh -> :membership_not_fresh
      truncated? -> :truncated_membership
      weight_health != :healthy -> :unhealthy_weight_facts
      true -> nil
    end
  end

  defp eta_sample_reason(run, counts, weights) do
    cond do
      weights.eligible == 0 -> :zero_eligible_weight
      counts.successful_terminal < 2 -> :insufficient_successful_completions
      run.elapsed_wall_seconds < 600 -> :insufficient_elapsed_time
      weights.successful_terminal <= 0 -> :zero_completed_weight
      true -> nil
    end
  end

  defp projection_health(
         run,
         source_health,
         membership_freshness,
         weight_health,
         truncated?
       ) do
    reasons =
      []
      |> maybe_reason(not run.valid?, :invalid_run_window)
      |> maybe_reason(source_health.membership != :healthy, :unhealthy_membership)
      |> maybe_reason(membership_freshness != :fresh, :membership_not_fresh)
      |> maybe_reason(source_health.status != :healthy, :unhealthy_status)
      |> maybe_reason(source_health.activity != :healthy, :unhealthy_activity)
      |> maybe_reason(source_health.issue != :healthy, :unhealthy_issue_facts)
      |> maybe_reason(weight_health != :healthy, :unhealthy_weight_facts)
      |> maybe_reason(truncated?, :truncated_membership)

    status =
      cond do
        not run.valid? or source_health.membership == :unavailable -> :unavailable
        reasons == [] -> :healthy
        true -> :partial
      end

    %{status: status, reasons: reasons}
  end

  defp maybe_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp projection_freshness(members, units, progress, membership_freshness) do
    source_freshness = units |> map_value(:freshness) |> normalize_freshness_map()
    source_statuses = Enum.map(source_freshness, fn {_source, status} -> freshness_status(status) end)

    status = projection_freshness_status(membership_freshness, stale_member?(members), source_statuses, progress)

    %{status: status, sources: source_freshness}
  end

  defp stale_member?(members) do
    Enum.any?(members, fn
      %{progress: {:unknown, :stale}} -> true
      _member -> false
    end)
  end

  defp projection_freshness_status(membership_freshness, stale_member?, source_statuses, progress) do
    [
      {membership_freshness == :unavailable, :unavailable},
      {membership_freshness == :unknown, :unknown},
      {membership_freshness == :stale, :stale},
      {stale_member?, :stale},
      {:stale in source_statuses, :stale},
      {membership_freshness == :partial, :partial},
      {:partial in source_statuses, :partial},
      {:unknown in source_statuses, :unknown},
      {progress.unknown_weight > 0, :partial}
    ]
    |> Enum.find_value(:fresh, fn
      {true, status} -> status
      {_matches?, _status} -> false
    end)
  end

  defp source_health(units) do
    health = map_value(units, :health)

    %{
      membership: health |> map_value(:membership, :unknown) |> health_status(),
      status: health |> map_value(:status, :unknown) |> health_status(),
      activity: health |> map_value(:activity, :unknown) |> health_status(),
      issue: health |> map_value(:issue, :unknown) |> health_status()
    }
  end

  defp source_provenance(units, source_health, membership_freshness, weight_health) do
    generations = map_value(units, :generation)

    %{
      run_generation: nil,
      membership_generation: map_value(generations, :membership),
      status_generation: map_value(generations, :status),
      activity_generation: map_value(generations, :activity),
      issue_generation: map_value(generations, :issue),
      membership_health: source_health.membership,
      status_health: source_health.status,
      activity_health: source_health.activity,
      issue_health: source_health.issue,
      membership_freshness: membership_freshness,
      weight_health: weight_health
    }
  end

  defp health_status(status) when status in [:healthy, :available, :writable], do: :healthy
  defp health_status(status) when status in [:degraded, :stale, :partial, :unknown], do: :degraded
  defp health_status({:degraded, _reason}), do: :degraded
  defp health_status({:unavailable, _reason}), do: :unavailable
  defp health_status(%{status: status}), do: health_status(status)
  defp health_status(_status), do: :unavailable

  defp freshness_status(%{status: status}), do: freshness_status(status)

  defp freshness_status(status)
       when status in [:fresh, :stale, :unknown, :unavailable, :partial],
       do: status

  defp freshness_status(_status), do: :unknown

  defp normalize_freshness_map(freshness) when is_map(freshness), do: freshness
  defp normalize_freshness_map(_freshness), do: %{}

  defp identity_key(row) do
    case Aiur.TrackerIdentity.github_key(Map.get(row, :identity)) do
      nil -> {:unjoinable, nil}
      key -> key
    end
  end

  defp fraction(_numerator, denominator) when not is_integer(denominator) or denominator <= 0,
    do: nil

  defp fraction(numerator, denominator) when is_integer(numerator) do
    divisor = Integer.gcd(abs(numerator), denominator)
    %{numerator: div(numerator, divisor), denominator: div(denominator, divisor)}
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp map_value(map, key, default \\ %{})

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_value(_map, _key, default), do: default
end
