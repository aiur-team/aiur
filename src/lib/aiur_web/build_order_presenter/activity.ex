defmodule AiurWeb.BuildOrderPresenter.Activity do
  @moduledoc "Exact-identity execution and activity indexes, with the sanitizers that keep raw provider data off the page."

  import AiurWeb.BuildOrderPresenter.Common

  alias Aiur.OpaqueIdentifier

  @safe_stages [:brainstorm, :plan, :work, :review]
  @safe_activity_statuses [:fresh, :stale]
  @safe_retention [:current, :recent]
  @safe_ci_decisions [:pass, :passed, :fail, :failed, :pending, :unknown]

  @doc false
  @spec execution_index(term()) :: {map(), MapSet.t(), :available | :unavailable}
  def execution_index(snapshot) when is_map(snapshot) do
    if Enum.all?([:running, :retrying, :idle], &is_list(Map.get(snapshot, &1))) do
      rows =
        Enum.flat_map([:running, :retrying, :idle], fn kind ->
          Enum.map(Map.fetch!(snapshot, kind), &{kind, &1})
        end)

      {index, duplicates} = exact_index(rows, &execution_identity/1)
      {index, duplicates, :available}
    else
      {%{}, MapSet.new(), :unavailable}
    end
  end

  def execution_index(_snapshot), do: {%{}, MapSet.new(), :unavailable}

  defp execution_identity({_kind, row}) when is_map(row), do: Map.get(row, :tracker_identity)
  defp execution_identity(_row), do: nil

  @doc false
  @spec execution_for(term(), map(), MapSet.t()) :: map()
  def execution_for(key, index, duplicates) do
    cond do
      MapSet.member?(duplicates, key) -> unknown_execution()
      match?({_, _}, Map.get(index, key)) -> index |> Map.fetch!(key) |> normalize_execution()
      true -> unknown_execution()
    end
  end

  defp normalize_execution({kind, row}) do
    %{
      status: :known,
      kind: kind,
      work_state: execution_work_state(kind, row),
      pause_reason: safe_atom(Map.get(row, :pause_reason)),
      waiting_reason: safe_atom(Map.get(row, :waiting_reason)),
      tracker_paused: boolean_or_unknown(Map.get(row, :tracker_paused)),
      runtime_seconds: non_negative_or_unknown(Map.get(row, :runtime_seconds)),
      ci_result: safe_ci_result(Map.get(row, :ci_result)),
      observed_at: execution_observed_at(row)
    }
  end

  defp execution_work_state(:running, row), do: safe_atom(Map.get(row, :work_state))
  defp execution_work_state(:retrying, _row), do: :retrying
  defp execution_work_state(:idle, _row), do: :idle

  defp execution_observed_at(row) do
    case Map.get(row, :last_codex_timestamp) || Map.get(row, :started_at) do
      %DateTime{} = datetime -> datetime
      _value -> nil
    end
  end

  defp safe_ci_result(%{decision: decision} = result) when decision in @safe_ci_decisions do
    %{
      status: :known,
      decision: decision,
      pr_number: positive_or_unknown(Map.get(result, :pr_number)),
      head_sha: OpaqueIdentifier.normalize(Map.get(result, :head_sha), 128),
      draft?: boolean_or_unknown(Map.get(result, :draft?))
    }
  end

  defp safe_ci_result(_result), do: %{status: :unknown}

  defp unknown_execution do
    %{
      status: :unknown,
      kind: :unknown,
      work_state: :unknown,
      pause_reason: :unknown,
      waiting_reason: :unknown,
      tracker_paused: :unknown,
      runtime_seconds: :unknown,
      ci_result: %{status: :unknown},
      observed_at: nil
    }
  end

  @doc false
  @spec activity_index(term()) :: {map(), MapSet.t(), :available | :unavailable, pos_integer() | :unknown}
  def activity_index(%{entries: entries} = snapshot) when is_list(entries) do
    {index, duplicates} = exact_index(entries, &activity_identity/1)
    generation = positive_or_unknown(Map.get(snapshot, :generation))
    {index, duplicates, :available, generation}
  end

  def activity_index(_snapshot), do: {%{}, MapSet.new(), :unavailable, :unknown}
  defp activity_identity(row) when is_map(row), do: Map.get(row, :identity)
  defp activity_identity(_row), do: nil

  @doc false
  @spec activity_for(term(), map(), MapSet.t()) :: map()
  def activity_for(key, index, duplicates) do
    cond do
      MapSet.member?(duplicates, key) -> unknown_activity()
      is_map(Map.get(index, key)) -> index |> Map.fetch!(key) |> normalize_activity()
      true -> unknown_activity()
    end
  end

  defp normalize_activity(row) do
    %{
      status: activity_status(Map.get(row, :status)),
      active_stage: safe_stage(Map.get(row, :active_stage)),
      stage: safe_stage_snapshot(Map.get(row, :stage)),
      progress: safe_progress_snapshot(Map.get(row, :progress)),
      latest_evidence: safe_evidence(Map.get(row, :latest_evidence)),
      provenance: safe_provenance(Map.get(row, :provenance)),
      observed_at: datetime_or_nil(Map.get(row, :observed_at)),
      retention: safe_retention(Map.get(row, :retention)),
      generation: positive_or_unknown(Map.get(row, :generation))
    }
  end

  defp safe_progress_snapshot(%{status: :known, percent: percent} = progress)
       when is_integer(percent) and percent in 0..100 do
    %{
      status: :known,
      percent: percent,
      source: safe_progress_source(Map.get(progress, :source)),
      freshness: activity_status(Map.get(progress, :freshness)),
      occurred_at: datetime_or_nil(Map.get(progress, :occurred_at)),
      observed_at: datetime_or_nil(Map.get(progress, :observed_at)),
      event_id: positive_or_unknown(Map.get(progress, :event_id))
    }
  end

  defp safe_progress_snapshot(_progress), do: %{status: :unknown}

  defp safe_stage_snapshot(%{status: :known} = stage) do
    %{
      status: :known,
      value: safe_stage(Map.get(stage, :value)),
      freshness: activity_status(Map.get(stage, :freshness)),
      observed_at: datetime_or_nil(Map.get(stage, :observed_at)),
      event_id: positive_or_unknown(Map.get(stage, :event_id))
    }
  end

  defp safe_stage_snapshot(_stage), do: %{status: :unknown}

  defp safe_evidence(%{status: :known} = evidence) do
    %{
      status: :known,
      source: safe_evidence_source(Map.get(evidence, :source)),
      attributes: safe_activity_attributes(Map.get(evidence, :attributes)),
      provenance: safe_provenance(Map.get(evidence, :provenance)),
      occurred_at: datetime_or_nil(Map.get(evidence, :occurred_at)),
      observed_at: datetime_or_nil(Map.get(evidence, :observed_at)),
      event_id: positive_or_unknown(Map.get(evidence, :event_id))
    }
  end

  defp safe_evidence(_evidence), do: %{status: :unknown}

  defp safe_evidence_source(%{kind: kind, name: name})
       when kind in [:agent_event, :agent_alert, :legacy] and is_binary(name) and byte_size(name) <= 64,
       do: %{kind: kind, name: name}

  defp safe_evidence_source(_source), do: %{kind: :legacy, name: "unclassified"}

  defp safe_activity_attributes(attributes) when is_map(attributes) do
    attributes
    |> Map.take([:percent, :stage, :transition, :needs_attention, :severity])
    |> Enum.reduce(%{}, &safe_activity_attribute/2)
  end

  defp safe_activity_attributes(_attributes), do: %{}

  defp safe_activity_attribute({:percent, value}, attributes) when is_integer(value) and value in 0..100,
    do: Map.put(attributes, :percent, value)

  defp safe_activity_attribute({:stage, value}, attributes) when value in @safe_stages,
    do: Map.put(attributes, :stage, value)

  defp safe_activity_attribute({:transition, value}, attributes) when value in [:start, :end],
    do: Map.put(attributes, :transition, value)

  defp safe_activity_attribute({:needs_attention, value}, attributes) when is_boolean(value),
    do: Map.put(attributes, :needs_attention, value)

  defp safe_activity_attribute({:severity, value}, attributes) when value in ["info", "warning", "critical"],
    do: Map.put(attributes, :severity, value)

  defp safe_activity_attribute(_attribute, attributes), do: attributes

  defp safe_provenance(provenance) when is_map(provenance) do
    provenance
    |> Map.take([:run_id, :attempt, :session_id, :source_event_id])
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_integer(value) and value >= 0 -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(value) -> maybe_put_opaque(acc, key, value)
      _entry, acc -> acc
    end)
  end

  defp safe_provenance(_provenance), do: %{}

  defp maybe_put_opaque(acc, key, value) do
    case OpaqueIdentifier.normalize(value, 128) do
      nil -> acc
      safe -> Map.put(acc, key, safe)
    end
  end

  defp unknown_activity do
    %{
      status: :unknown,
      active_stage: :unknown,
      stage: %{status: :unknown},
      progress: %{status: :unknown},
      latest_evidence: %{status: :unknown},
      provenance: %{},
      observed_at: nil,
      retention: :unknown,
      generation: :unknown
    }
  end

  @doc false
  @spec current_activity_stage(term()) :: atom()
  def current_activity_stage(%{
        status: :fresh,
        stage: %{status: :known, freshness: :fresh, value: stage}
      })
      when stage in @safe_stages,
      do: stage

  def current_activity_stage(_activity), do: :unknown

  @doc false
  # A known percent is worth carrying once the row or the reading has gone stale:
  # a paused worker stops emitting, it does not stop having done the work.
  # `progress_freshness` says how current that percent is, so no consumer can
  # mistake a last-known reading for a live one. A missing or unknown reading
  # stays `:unknown`; no percent is ever invented for it.
  @spec activity_progress(term()) :: 0..100 | :unknown
  def activity_progress(%{
        status: status,
        progress: %{status: :known, freshness: freshness, percent: percent}
      })
      when status in @safe_activity_statuses and freshness in @safe_activity_statuses and percent in 0..100,
      do: percent

  def activity_progress(_activity), do: :unknown

  @doc false
  @spec activity_progress_freshness(term()) :: :fresh | :stale | :unknown
  def activity_progress_freshness(%{status: :fresh, progress: %{freshness: :fresh}} = activity) do
    if activity_progress(activity) == :unknown, do: :unknown, else: :fresh
  end

  def activity_progress_freshness(activity) do
    if activity_progress(activity) == :unknown, do: :unknown, else: :stale
  end

  @doc false
  @spec activity_progress_observed_at(term()) :: DateTime.t() | nil
  def activity_progress_observed_at(%{progress: %{observed_at: %DateTime{} = observed_at}} = activity) do
    if activity_progress(activity) == :unknown, do: nil, else: observed_at
  end

  def activity_progress_observed_at(_activity), do: nil

  defp exact_index(rows, identity_fun) do
    Enum.reduce(rows, {%{}, MapSet.new()}, fn row, {index, duplicates} ->
      key = row |> identity_fun.() |> identity_key()

      cond do
        is_nil(key) -> {index, duplicates}
        Map.has_key?(index, key) -> {Map.delete(index, key), MapSet.put(duplicates, key)}
        MapSet.member?(duplicates, key) -> {index, duplicates}
        true -> {Map.put(index, key, row), duplicates}
      end
    end)
  end

  defp safe_atom(value) when is_atom(value) and not is_nil(value), do: value
  defp safe_atom(_value), do: :unknown
  defp boolean_or_unknown(value) when is_boolean(value), do: value
  defp boolean_or_unknown(_value), do: :unknown
  defp non_negative_or_unknown(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_or_unknown(_value), do: :unknown
  defp positive_or_unknown(value) when is_integer(value) and value > 0, do: value
  defp positive_or_unknown(_value), do: :unknown
  defp datetime_or_nil(%DateTime{} = value), do: value
  defp datetime_or_nil(_value), do: nil
  defp activity_status(value) when value in @safe_activity_statuses, do: value
  defp activity_status(_value), do: :unknown
  defp safe_stage(value) when value in @safe_stages, do: value
  defp safe_stage(_value), do: :unknown
  defp safe_progress_source(value) when value in [:checkin, :phase], do: value
  defp safe_progress_source(_value), do: :unknown
  defp safe_retention(value) when value in @safe_retention, do: value
  defp safe_retention(_value), do: :unknown
end
