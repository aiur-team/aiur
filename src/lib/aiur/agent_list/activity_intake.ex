defmodule Aiur.AgentList.ActivityIntake do
  @moduledoc """
  Adapts daemon-owned `Aiur.TicketActivity` snapshots for AgentList rendering.

  Activity is joined by `Aiur.TrackerIdentity`; identifier-keyed maps exist
  only as presentation inputs for the existing renderer.
  """

  alias Aiur.AgentList.Summaries
  alias Aiur.TrackerIdentity

  @spec load(map(), map()) :: map()
  def load(state, %{generation: generation, entries: entries})
      when is_integer(generation) and generation >= 0 and is_list(entries) do
    activities =
      entries
      |> Enum.filter(&joinable_entry?/1)
      |> Map.new(fn entry -> {key(entry.identity), entry} end)

    state
    |> Map.put(:ticket_activity_generation, generation)
    |> Map.put(:ticket_activity_by_identity, activities)
    |> reconcile()
  end

  def load(state, _snapshot), do: state

  @spec fold(map(), map()) :: {:ok, map()} | :reload
  def fold(state, %{generation: generation} = payload)
      when is_integer(generation) and generation >= 0 do
    current = Map.get(state, :ticket_activity_generation, -1)

    cond do
      generation <= current -> {:ok, state}
      generation != current + 1 -> :reload
      valid_update?(payload) -> apply_entry(state, payload)
      true -> :reload
    end
  end

  def fold(_state, _payload), do: :reload

  @spec reconcile(map()) :: map()
  def reconcile(state) do
    previous = Map.get(state, :ticket_activity_presented, %{})

    presentation =
      state
      |> Map.get(:summaries, [])
      |> Enum.reduce(empty_presentation(), &present_summary(&1, &2, state, previous))

    state
    |> Map.merge(Map.drop(presentation, [:presented]))
    |> Map.put(:ticket_activity_presented, presentation.presented)
    |> seed_deactivated_progress()
  end

  # Forces progress_by_id to 100% for any deactivated (human-review) summary,
  # regardless of what the agent last emitted. Runs at the end of every
  # reconcile so the bar stays green even if a stale activity snapshot
  # overwrites the prior 100% sample.
  defp seed_deactivated_progress(state) do
    now_ms = System.monotonic_time(:millisecond)

    state
    |> Map.get(:summaries, [])
    |> Enum.filter(&Summaries.deactivated?/1)
    |> Enum.reduce(state, fn summary, acc ->
      case Map.get(summary, :identifier) do
        id when is_binary(id) ->
          case get_in(acc, [:progress_by_id, id]) do
            [{100, _} | _] -> acc
            _ -> put_in(acc, [:progress_by_id, id], [{100, now_ms}])
          end

        _ ->
          acc
      end
    end)
  end

  defp apply_entry(state, payload) do
    identity = payload.identity
    identity_key = key(identity)
    activities = Map.get(state, :ticket_activity_by_identity, %{})

    activities =
      case payload[:snapshot] do
        %{identity: snapshot_identity} = snapshot ->
          if key(snapshot_identity) == identity_key,
            do: Map.put(activities, identity_key, snapshot),
            else: activities

        _ ->
          Map.delete(activities, identity_key)
      end

    next =
      state
      |> Map.put(:ticket_activity_generation, payload.generation)
      |> Map.put(:ticket_activity_by_identity, activities)
      |> reconcile()

    {:ok, next}
  end

  defp present_summary(summary, acc, state, previous) do
    with identifier when is_binary(identifier) <- Map.get(summary, :identifier),
         %TrackerIdentity{} = identity <- Map.get(summary, :tracker_identity),
         identity_key when not is_nil(identity_key) <- key(identity),
         %{} = activity <- get_in(state, [:ticket_activity_by_identity, identity_key]) do
      present_activity(acc, identifier, identity_key, activity, previous, state)
    else
      _ -> acc
    end
  end

  defp present_activity(acc, identifier, identity_key, activity, previous, state) do
    acc
    |> put_progress(identifier, identity_key, activity, previous, state)
    |> put_stage(identifier, activity)
    |> put_evidence(identifier, activity)
    |> put_status(identifier, activity)
    |> put_in([:presented, identity_key], activity)
  end

  defp put_progress(acc, identifier, identity_key, activity, previous, state) do
    case activity[:progress] do
      %{status: :known, percent: percent, observed_at: observed_at}
      when is_integer(percent) and percent >= 0 and percent <= 100 ->
        old_activity = Map.get(previous, identity_key)
        old_samples = get_in(state, [:progress_by_id, identifier]) || []
        samples = progress_samples(old_samples, old_activity, activity, percent, observed_at)
        put_in(acc, [:progress_by_id, identifier], samples)

      _ ->
        acc
    end
  end

  defp progress_samples(samples, old_activity, activity, percent, observed_at) do
    timestamp = monotonic_timestamp(observed_at)

    cond do
      generation_changed?(old_activity, activity) -> [{percent, timestamp}]
      match?([{^percent, _} | _], samples) -> [{percent, timestamp} | tl(samples)]
      true -> Aiur.ProgressTracker.record(samples, percent, timestamp)
    end
  end

  defp put_stage(acc, identifier, activity) do
    case activity[:stage] do
      %{status: :known, freshness: :fresh, value: stage}
      when stage in [:brainstorm, :plan, :work, :review] ->
        put_in(acc, [:phase_by_identifier, identifier], stage)

      _ ->
        acc
    end
  end

  defp put_evidence(acc, identifier, activity) do
    case activity[:latest_evidence] do
      %{status: :known} = evidence ->
        event = %{
          message: evidence_message(evidence),
          source: evidence[:source],
          timestamp: evidence[:observed_at],
          stale?: activity[:status] == :stale
        }

        put_in(acc, [:latest_event_by_id, identifier], event)

      _ ->
        acc
    end
  end

  defp put_status(acc, identifier, activity) do
    status = %{
      snapshot: activity[:status] || :unknown,
      progress: field_status(activity[:progress]),
      stage: field_status(activity[:stage]),
      evidence: field_status(activity[:latest_evidence])
    }

    put_in(acc, [:activity_status_by_identifier, identifier], status)
  end

  defp empty_presentation do
    %{
      latest_event_by_id: %{},
      phase_by_identifier: %{},
      progress_by_id: %{},
      activity_status_by_identifier: %{},
      presented: %{}
    }
  end

  defp field_status(%{status: :known, freshness: freshness}), do: freshness
  defp field_status(%{status: status}), do: status
  defp field_status(_field), do: :unknown

  defp evidence_message(%{source: %{kind: :agent_event}, attributes: %{percent: percent}}),
    do: "Progress #{percent}%"

  defp evidence_message(%{source: %{kind: :agent_alert, name: "phase." <> rest}}) do
    rest |> String.replace(".", " ") |> String.capitalize()
  end

  defp evidence_message(%{attributes: %{needs_attention: true}}), do: "Needs attention"
  defp evidence_message(%{source: %{kind: :agent_alert}}), do: "Agent alert"
  defp evidence_message(_evidence), do: "Agent activity"

  defp generation_changed?(nil, _activity), do: true

  defp generation_changed?(old_activity, activity) do
    old = get_in(old_activity, [:progress, :provenance]) || %{}
    new = get_in(activity, [:progress, :provenance]) || %{}
    Enum.any?([:run_id, :attempt, :session_id], &(Map.get(old, &1) != Map.get(new, &1)))
  end

  defp monotonic_timestamp(%DateTime{} = observed_at) do
    now = DateTime.utc_now()
    System.monotonic_time(:millisecond) + DateTime.diff(observed_at, now, :millisecond)
  end

  defp monotonic_timestamp(_observed_at), do: System.monotonic_time(:millisecond)
  defp valid_update?(%{identity: identity, snapshot: :not_found}), do: TrackerIdentity.joinable?(identity)

  defp valid_update?(%{identity: identity, snapshot: %{identity: snapshot_identity}}) do
    identity_key = key(identity)
    not is_nil(identity_key) and key(snapshot_identity) == identity_key
  end

  defp valid_update?(_payload), do: false
  defp joinable_entry?(%{identity: identity}), do: not is_nil(key(identity))
  defp joinable_entry?(_entry), do: false
  defp key(identity), do: TrackerIdentity.github_key(identity)
end
