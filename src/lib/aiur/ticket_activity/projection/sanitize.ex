defmodule Aiur.TicketActivity.Projection.Sanitize do
  @moduledoc false

  alias Aiur.OpaqueIdentifier

  @spec safe_source(term()) :: map()
  def safe_source(%{kind: :agent_event, name: name})
      when name in ["progress", "progress.checkin", "progress.phase"],
      do: %{kind: :agent_event, name: name}

  def safe_source(%{kind: :agent_alert, name: "alert"}), do: %{kind: :agent_alert, name: "alert"}

  def safe_source(%{kind: :agent_alert, name: name}) do
    case phase_source(name) do
      {:ok, stage, transition} ->
        %{kind: :agent_alert, name: "phase.#{stage}.#{transition}"}

      _ ->
        %{kind: :agent_alert, name: "alert"}
    end
  end

  def safe_source(%{kind: :legacy}), do: %{kind: :legacy, name: "unclassified"}

  def safe_source(_source), do: %{kind: :legacy, name: "unclassified"}

  @spec safe_attributes(term()) :: map()
  def safe_attributes(attributes) when is_map(attributes) do
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

  def safe_attributes(_attributes), do: %{}

  @spec safe_provenance(term()) :: map()
  def safe_provenance(provenance) when is_map(provenance) do
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

  def safe_provenance(_provenance), do: %{}

  defp put_safe_opaque(acc, key, value) do
    case OpaqueIdentifier.normalize(value) do
      nil -> acc
      safe -> Map.put(acc, key, safe)
    end
  end

  @spec phase_source(term()) :: {:ok, atom(), atom()} | :error
  def phase_source("phase." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [stage, transition]
      when stage in ["brainstorm", "plan", "work", "review"] and transition in ["start", "end"] ->
        {:ok, String.to_existing_atom(stage), String.to_existing_atom(transition)}

      _ ->
        :error
    end
  end

  def phase_source(_name), do: :error
  @spec safe_timestamp(term()) :: DateTime.t() | nil
  def safe_timestamp(%DateTime{} = timestamp), do: timestamp
  def safe_timestamp(_timestamp), do: nil
  @spec safe_event_id(term()) :: pos_integer() | nil
  def safe_event_id(event_id) when is_integer(event_id) and event_id > 0, do: event_id
  def safe_event_id(_event_id), do: nil
end
