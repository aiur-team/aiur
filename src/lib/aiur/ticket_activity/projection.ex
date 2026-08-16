defmodule Aiur.TicketActivity.Projection do
  @moduledoc false

  alias Aiur.{OpaqueIdentifier, TicketActivity.Reducer, TicketObservation, TrackerIdentity}

  @default_retention_ms 300_000
  @default_stale_after_ms 60_000
  @default_max_recent 100
  @progress_generation_keys [:run_id, :attempt, :session_id]

  @type entry :: %{
          required(:identity) => TrackerIdentity.t(),
          required(:retention) => :current | :recent,
          required(:first_observed_at) => DateTime.t(),
          required(:last_observed_at) => DateTime.t(),
          required(:latest_evidence) => map() | nil,
          required(:progress_order) => tuple() | nil,
          required(:stage_order) => tuple() | nil,
          optional(:progress) => map(),
          optional(:stage) => map()
        }

  @opaque t :: %__MODULE__{}

  defstruct entries: %{},
            current_keys: MapSet.new(),
            generation: 0,
            retention_ms: @default_retention_ms,
            stale_after_ms: @default_stale_after_ms,
            max_recent: @default_max_recent,
            diagnostics: %{unattributed: 0, invalid: 0, unsupported: 0, evicted: 0}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      retention_ms: positive_opt(opts, :retention_ms, @default_retention_ms),
      stale_after_ms: positive_opt(opts, :stale_after_ms, @default_stale_after_ms),
      max_recent: positive_opt(opts, :max_recent, @default_max_recent)
    }
  end

  @spec refresh_members(t(), [TrackerIdentity.t()], DateTime.t()) :: t()
  def refresh_members(%__MODULE__{} = state, identities, now \\ DateTime.utc_now())
      when is_list(identities) do
    keys =
      identities
      |> Enum.filter(&TrackerIdentity.joinable?/1)
      |> Enum.map(&key/1)
      |> MapSet.new()

    entries =
      Map.new(state.entries, fn {entry_key, entry} ->
        retention = if MapSet.member?(keys, entry_key), do: :current, else: :recent
        {entry_key, %{entry | retention: retention}}
      end)

    retention_changed? = entries != state.entries
    state = %{state | current_keys: keys, entries: entries}
    state = if retention_changed?, do: %{state | generation: state.generation + 1}, else: state
    prune(state, now)
  end

  @doc """
  Seeds projection entries from durable retained progress readings.

  Called at boot, after `refresh_members/3`, so a projection or daemon restart
  does not re-enter `unknown` for tickets that already reported: every retained
  reading becomes a projection entry whose freshness is computed honestly from
  its own `observed_at` (a just-landed reading stays `:fresh`, an old one
  renders `:stale` — both with the real percent). A ticket with no retained
  reading stays `:unknown`, which is exactly the "never reported" state.

  Does not prune: retained `:recent` readings may outlive the in-memory
  retention window at boot and are trimmed by the normal prune cycle, while the
  durable store (and `StatusReport`'s retained fallback) keep showing the last
  known value. A newer progress `order` already present on an existing entry
  wins over the seed.
  """
  @spec seed_progress(t(), [{TrackerIdentity.t(), map()}], DateTime.t()) :: t()
  def seed_progress(%__MODULE__{} = state, retained, now \\ DateTime.utc_now()) when is_list(retained) do
    entries =
      Enum.reduce(retained, state.entries, &seed_progress_entry(&1, &2, state, now))

    %{state | entries: entries, generation: state.generation + 1}
  end

  defp seed_progress_entry({identity, progress}, entries, state, now) do
    entry_key = key(identity)

    if is_nil(entry_key) or not is_map(progress) do
      entries
    else
      Map.put(entries, entry_key, winning_seed_entry(entries, entry_key, state, identity, progress, now))
    end
  end

  defp winning_seed_entry(entries, entry_key, state, identity, progress, now) do
    case Map.get(entries, entry_key) do
      %{progress: %{order: existing_order}} = existing when is_tuple(existing_order) ->
        if newer_progress?(progress, existing_order),
          do: seeded_entry(state, identity, progress, now),
          else: existing

      _existing ->
        seeded_entry(state, identity, progress, now)
    end
  end

  defp seeded_entry(state, identity, progress, now) do
    observed_at = Map.get(progress, :observed_at) || now

    %{
      identity: identity,
      retention: if(MapSet.member?(state.current_keys, key(identity)), do: :current, else: :recent),
      first_observed_at: observed_at,
      last_observed_at: observed_at,
      provenance: Map.get(progress, :provenance),
      latest_evidence: nil,
      progress: progress,
      progress_order: Map.get(progress, :order),
      stage: nil,
      stage_order: nil
    }
  end

  defp newer_progress?(%{order: order}, existing_order) when is_tuple(order) and is_tuple(existing_order),
    do: order > existing_order

  defp newer_progress?(_progress, _existing_order), do: true

  @spec apply(t(), TicketObservation.t()) :: {:accepted, t()} | {:ignored, atom(), t()}
  def apply(%__MODULE__{} = state, %TicketObservation{} = observation) do
    cond do
      observation.status != :joinable or
          not TrackerIdentity.joinable?(observation.tracker_identity) ->
        {:ignored, :unattributed, increment(state, :unattributed)}

      not is_struct(observation.observed_at, DateTime) ->
        {:ignored, :invalid, increment(state, :invalid)}

      true ->
        apply_observation(state, observation)
    end
  end

  def apply(%__MODULE__{} = state, _observation),
    do: {:ignored, :invalid, increment(state, :invalid)}

  @spec prune(t(), DateTime.t()) :: t()
  def prune(%__MODULE__{} = state, %DateTime{} = now) do
    {expired, retained} =
      Enum.split_with(state.entries, fn {_entry_key, entry} ->
        entry.retention == :recent and
          DateTime.diff(now, entry.last_observed_at, :millisecond) > state.retention_ms
      end)

    retained = retain_recent_cap(retained, state.max_recent)
    evicted = length(expired) + (map_size(state.entries) - length(expired) - length(retained))

    if evicted == 0 do
      state
    else
      diagnostics = Map.update!(state.diagnostics, :evicted, &(&1 + evicted))

      %{
        state
        | entries: Map.new(retained),
          generation: state.generation + 1,
          diagnostics: diagnostics
      }
    end
  end

  @spec snapshot(t(), TrackerIdentity.t(), DateTime.t()) :: map() | :not_found
  def snapshot(state, identity, now \\ DateTime.utc_now())

  def snapshot(%__MODULE__{} = state, %TrackerIdentity{} = identity, now) do
    case TrackerIdentity.github_key(identity) do
      nil -> :not_found
      entry_key -> state.entries |> Map.get(entry_key) |> snapshot_entry(state, now)
    end
  end

  def snapshot(_state, _identity, _now), do: :not_found

  @spec snapshots(t(), DateTime.t()) :: map()
  def snapshots(%__MODULE__{} = state, now \\ DateTime.utc_now()) do
    entries =
      state.entries
      |> Map.values()
      |> Enum.sort_by(fn entry -> key(entry.identity) end)
      |> Enum.map(&snapshot_entry(&1, state, now))

    %{
      generation: state.generation,
      entries: entries,
      retention: retention(state),
      diagnostics: state.diagnostics
    }
  end

  @doc """
  The raw ordered progress reading held for `identity`, or `nil`.

  The durable retention store needs the reading itself — `percent`, `source`,
  `provenance`, `occurred_at`, `observed_at`, `event_id`, `order` — rather than
  the freshness-resolved `snapshot/3` projection of it. Returns `nil` for an
  unknown identity or for an entry that has never carried an ordered reading,
  which keeps the entry map behind the opaque projection boundary.
  """
  @spec ordered_progress(t(), TrackerIdentity.t()) :: map() | nil
  def ordered_progress(%__MODULE__{} = state, %TrackerIdentity{} = identity) do
    case TrackerIdentity.github_key(identity) do
      nil -> nil
      entry_key -> state.entries |> Map.get(entry_key) |> entry_ordered_progress()
    end
  end

  def ordered_progress(_state, _identity), do: nil

  defp entry_ordered_progress(%{progress: %{order: _} = progress}), do: progress
  defp entry_ordered_progress(_entry), do: nil

  @spec generation(t()) :: non_neg_integer()
  def generation(%__MODULE__{generation: generation}), do: generation

  @spec diagnostics(t()) :: map()
  def diagnostics(%__MODULE__{diagnostics: diagnostics}), do: diagnostics

  defp apply_observation(state, observation) do
    entry_key = key(observation.tracker_identity)
    order = ordering(observation)
    entry = Map.get(state.entries, entry_key, new_entry(state, observation))
    {entry, progress_changed?} = fold_progress(entry, observation, order)
    {entry, stage_changed?} = fold_stage(entry, observation, order)
    {entry, evidence_changed?} = fold_evidence(entry, observation, order)
    unsupported? = not supported?(observation)
    changed? = progress_changed? or stage_changed? or evidence_changed?

    state = if unsupported?, do: increment(state, :unsupported), else: state

    if changed? do
      updated = %{
        entry
        | last_observed_at: newer_time(entry.last_observed_at, observation.observed_at)
      }

      {:accepted,
       %{
         state
         | entries: Map.put(state.entries, entry_key, updated),
           generation: state.generation + 1
       }}
    else
      {:ignored, :duplicate, state}
    end
  end

  defp new_entry(state, observation) do
    %{
      identity: observation.tracker_identity,
      retention:
        if(MapSet.member?(state.current_keys, key(observation.tracker_identity)),
          do: :current,
          else: :recent
        ),
      first_observed_at: observation.observed_at,
      last_observed_at: observation.observed_at,
      provenance: safe_provenance(observation.provenance),
      latest_evidence: nil,
      progress: nil,
      progress_order: nil,
      stage: nil,
      stage_order: nil
    }
  end

  defp fold_progress(entry, observation, order) do
    case progress(observation) do
      nil ->
        {entry, false}

      %{percent: percent, source: source} ->
        fold_ordered_progress(entry, observation, order, percent, source)
    end
  end

  defp fold_ordered_progress(entry, observation, order, percent, source) do
    if newer_order?(order, entry.progress_order) do
      entry = %{entry | progress_order: order}
      apply_progress(entry, observation, order, percent, source)
    else
      {entry, false}
    end
  end

  defp apply_progress(entry, observation, order, percent, source) do
    current = entry.progress

    if Reducer.accept_progress?(
         source,
         percent,
         current_percent(current),
         provenance_changed?(current, observation)
       ) do
      progress = progress_value(observation, order, percent, source)
      {%{entry | progress: progress, provenance: progress.provenance}, true}
    else
      {entry, true}
    end
  end

  defp progress_value(observation, order, percent, source) do
    %{
      percent: percent,
      source: source,
      provenance: safe_provenance(observation.provenance),
      occurred_at: safe_timestamp(observation.occurred_at),
      observed_at: observation.observed_at,
      event_id: safe_event_id(observation.event_id),
      order: order
    }
  end

  defp fold_stage(entry, observation, order) do
    case stage(observation) do
      %{stage: stage, transition: transition} when not is_nil(stage) ->
        fold_ordered_stage(entry, observation, order, stage, transition)

      _ ->
        {entry, false}
    end
  end

  defp fold_ordered_stage(entry, observation, order, stage, transition) do
    if newer_order?(order, entry.stage_order) do
      entry = %{entry | stage_order: order}
      apply_stage(entry, observation, order, stage, transition)
    else
      {entry, false}
    end
  end

  defp apply_stage(entry, observation, order, stage, transition) do
    current = entry.stage && entry.stage.value

    case Reducer.transition_stage(current, stage, transition) do
      {:set, value} ->
        {%{entry | stage: stage_value(observation, order, value)}, true}

      :clear ->
        {%{entry | stage: stage_value(observation, order, nil)}, true}

      :keep ->
        {entry, true}
    end
  end

  defp stage_value(observation, order, value) do
    %{
      value: value,
      observed_at: observation.observed_at,
      event_id: safe_event_id(observation.event_id),
      order: order
    }
  end

  defp fold_evidence(entry, observation, order) do
    if newer?(order, entry.latest_evidence) do
      evidence = %{
        source: safe_source(observation.source),
        attributes: safe_attributes(observation.attributes),
        provenance: safe_provenance(observation.provenance),
        occurred_at: safe_timestamp(observation.occurred_at),
        observed_at: observation.observed_at,
        event_id: safe_event_id(observation.event_id),
        order: order
      }

      {%{entry | latest_evidence: evidence, provenance: evidence.provenance}, true}
    else
      {entry, false}
    end
  end

  defp progress(%TicketObservation{
         source: %{kind: :agent_event, name: name},
         attributes: attributes
       })
       when name in ["progress", "progress.checkin", "progress.phase"] do
    case Map.get(attributes, :percent) do
      percent when is_integer(percent) and percent >= 0 and percent <= 100 ->
        %{percent: percent, source: if(name == "progress.checkin", do: :checkin, else: :phase)}

      _ ->
        nil
    end
  end

  defp progress(_observation), do: nil

  defp stage(%TicketObservation{
         source: %{kind: :agent_alert, name: source_name},
         attributes: attributes
       }) do
    with {:ok, stage, transition} <- phase_source(source_name),
         ^stage <- Map.get(attributes, :stage),
         ^transition <- Map.get(attributes, :transition) do
      %{stage: stage, transition: transition}
    else
      _ -> nil
    end
  end

  defp stage(_observation), do: nil

  defp supported?(observation),
    do: not is_nil(progress(observation)) or not is_nil(stage(observation))

  defp current_percent(nil), do: 0
  defp current_percent(%{percent: percent}), do: percent
  defp provenance_changed?(nil, _observation), do: false

  defp provenance_changed?(%{provenance: current}, observation) do
    incoming = safe_provenance(observation.provenance)

    Enum.any?(@progress_generation_keys, fn key ->
      Map.has_key?(incoming, key) and Map.get(current, key) != Map.fetch!(incoming, key)
    end)
  end

  defp newer?(_order, nil), do: true
  defp newer?(order, %{order: previous}), do: order > previous
  defp newer_order?(_order, nil), do: true
  defp newer_order?(order, previous), do: order > previous

  defp ordering(observation),
    do: {DateTime.to_unix(observation.observed_at, :microsecond), safe_event_id(observation.event_id) || 0}

  defp newer_time(left, right),
    do: if(DateTime.compare(left, right) == :lt, do: right, else: left)

  defp key(identity), do: TrackerIdentity.github_key(identity)

  defp snapshot_entry(nil, _state, _now), do: :not_found

  defp snapshot_entry(entry, state, now) do
    %{
      identity: entry.identity,
      status: freshness(entry.last_observed_at, state, now),
      active_stage: entry.stage && entry.stage.value,
      stage: stage_snapshot(entry.stage, state, now),
      progress: progress_snapshot(entry.progress, state, now),
      latest_evidence: evidence_snapshot(entry.latest_evidence),
      provenance: entry.provenance,
      observed_at: entry.last_observed_at,
      retention: entry.retention
    }
  end

  defp progress_snapshot(nil, _state, _now), do: %{status: :unknown}

  defp progress_snapshot(progress, state, now) do
    progress
    |> Map.drop([:order])
    |> Map.put(:status, :known)
    |> Map.put(:freshness, freshness(progress.observed_at, state, now))
  end

  defp stage_snapshot(nil, _state, _now), do: %{status: :unknown}

  defp stage_snapshot(stage, state, now) do
    stage
    |> Map.drop([:order])
    |> Map.put(:status, :known)
    |> Map.put(:freshness, freshness(stage.observed_at, state, now))
  end

  defp evidence_snapshot(nil), do: %{status: :unknown}

  defp evidence_snapshot(evidence) do
    evidence
    |> Map.drop([:order])
    |> Map.put(:status, :known)
  end

  defp freshness(observed_at, state, now) do
    if DateTime.diff(now, observed_at, :millisecond) > state.stale_after_ms,
      do: :stale,
      else: :fresh
  end

  defp retention(state) do
    %{
      current: Enum.count(state.entries, fn {_key, entry} -> entry.retention == :current end),
      recent: Enum.count(state.entries, fn {_key, entry} -> entry.retention == :recent end),
      evicted: state.diagnostics.evicted
    }
  end

  defp retain_recent_cap(entries, max_recent) do
    {current, recent} =
      Enum.split_with(entries, fn {_key, entry} -> entry.retention == :current end)

    recent =
      recent
      |> Enum.sort_by(fn {_key, entry} -> entry.last_observed_at end, {:desc, DateTime})
      |> Enum.take(max_recent)

    current ++ recent
  end

  defp increment(state, key),
    do: %{state | diagnostics: Map.update!(state.diagnostics, key, &(&1 + 1))}

  defp safe_source(%{kind: :agent_event, name: name})
       when name in ["progress", "progress.checkin", "progress.phase"],
       do: %{kind: :agent_event, name: name}

  defp safe_source(%{kind: :agent_alert, name: "alert"}), do: %{kind: :agent_alert, name: "alert"}

  defp safe_source(%{kind: :agent_alert, name: name}) do
    case phase_source(name) do
      {:ok, stage, transition} ->
        %{kind: :agent_alert, name: "phase.#{stage}.#{transition}"}

      _ ->
        %{kind: :agent_alert, name: "alert"}
    end
  end

  defp safe_source(%{kind: :legacy}), do: %{kind: :legacy, name: "unclassified"}

  defp safe_source(_source), do: %{kind: :legacy, name: "unclassified"}

  defp safe_attributes(attributes) when is_map(attributes) do
    attributes
    |> Map.take([:percent, :stage, :transition, :needs_attention, :severity])
    |> Enum.reduce(%{}, fn
      {:percent, percent}, acc when is_integer(percent) and percent >= 0 and percent <= 100 ->
        Map.put(acc, :percent, percent)

      {:stage, stage}, acc when stage in [:brainstorm, :plan, :work, :review] ->
        Map.put(acc, :stage, stage)

      {:transition, transition}, acc when transition in [:start, :end] ->
        Map.put(acc, :transition, transition)

      {:needs_attention, value}, acc when is_boolean(value) ->
        Map.put(acc, :needs_attention, value)

      {:severity, severity}, acc when severity in ["info", "warning", "critical"] ->
        Map.put(acc, :severity, severity)

      _entry, acc ->
        acc
    end)
  end

  defp safe_attributes(_attributes), do: %{}

  defp safe_provenance(provenance) when is_map(provenance) do
    Enum.reduce([:run_id, :attempt, :session_id, :source_event_id], %{}, fn key, acc ->
      case Map.get(provenance, key) do
        value when is_integer(value) and value >= 0 ->
          Map.put(acc, key, value)

        value when is_binary(value) ->
          put_safe_opaque(acc, key, value)

        _ ->
          acc
      end
    end)
  end

  defp safe_provenance(_provenance), do: %{}

  defp put_safe_opaque(acc, key, value) do
    case OpaqueIdentifier.normalize(value) do
      nil -> acc
      safe -> Map.put(acc, key, safe)
    end
  end

  defp phase_source("phase." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [stage, transition]
      when stage in ["brainstorm", "plan", "work", "review"] and transition in ["start", "end"] ->
        {:ok, String.to_existing_atom(stage), String.to_existing_atom(transition)}

      _ ->
        :error
    end
  end

  defp phase_source(_name), do: :error
  defp safe_timestamp(%DateTime{} = timestamp), do: timestamp
  defp safe_timestamp(_timestamp), do: nil
  defp safe_event_id(event_id) when is_integer(event_id) and event_id > 0, do: event_id
  defp safe_event_id(_event_id), do: nil

  defp positive_opt(opts, key, default),
    do: if(is_integer(opts[key]) and opts[key] > 0, do: opts[key], else: default)
end
