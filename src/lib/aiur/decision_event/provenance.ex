defmodule Aiur.DecisionEvent.Provenance do
  @moduledoc false

  alias Aiur.{Decision, DecisionProvenance, DecisionValidation}
  alias Aiur.DecisionEvent.{Codec, Validation}
  @schema_version 1
  @versioned_snapshot_schema_version 2
  @provenance_event_id_prefix "decision-provenance-v1:"

  @spec event_data_to_json_safe(term()) :: map()
  def event_data_to_json_safe(%Aiur.DecisionEvent{schema_version: @schema_version} = event) do
    Codec.data_to_json_safe(event.type, event.data)
    |> maybe_put_provenance_binding(event.type, event.data, event)
  end

  def event_data_to_json_safe(%Aiur.DecisionEvent{schema_version: @versioned_snapshot_schema_version} = event),
    do: Codec.data_to_json_safe(event.type, event.data) |> maybe_put_provenance_state(event.type, event.data)

  defp maybe_put_provenance_binding(data, type, event_data, %Aiur.DecisionEvent{} = event)
       when type in [:requested, :enriched] do
    state = if provenance_for(type, event_data), do: "captured", else: "unknown"

    data
    |> Map.put("provenance_state", state)
    |> Map.put(
      "provenance_hash",
      DecisionValidation.content_hash(provenance_material(type, event, provenance_for(type, event_data), state))
    )
  end

  defp maybe_put_provenance_binding(data, _type, _event_data, _event), do: data

  defp provenance_for(:requested, %Decision{} = decision), do: decision.provenance
  defp provenance_for(:enriched, %{decision: %Decision{} = decision}), do: decision.provenance
  defp provenance_for(_type, _data), do: nil

  @spec maybe_put_provenance_state(term(), term(), term()) :: map()
  def maybe_put_provenance_state(data, type, event_data) when type in [:requested, :enriched] do
    state = if provenance_for(type, event_data), do: "captured", else: "unknown"
    Map.put(data, "provenance_state", state)
  end

  def maybe_put_provenance_state(data, _type, _event_data), do: data

  @spec maybe_put_provenance_state(term(), term()) :: map()
  def maybe_put_provenance_state(data, nil), do: data
  def maybe_put_provenance_state(data, state), do: Map.put(data, :provenance_state, state)

  defp provenance_material(type, event, provenance, state) do
    %{
      schema_version: @schema_version,
      event_type: type,
      event_id: event.event_id,
      run_id: event.run_id,
      decision_id: event.decision_id,
      decision_version: event.decision_version,
      occurred_at: DateTime.to_iso8601(event.occurred_at),
      provenance: provenance && DecisionProvenance.to_json_safe(provenance)
    }
    |> maybe_put_provenance_state(state)
  end

  @spec decode_typed_provenance(term(), term(), term(), term(), term(), term(), term(), term()) :: {:ok, term()} | {:error, term()}
  def decode_typed_provenance(
        @schema_version,
        :requested,
        data,
        event_id,
        run_id,
        decision_id,
        decision_version,
        occurred_at
      ) do
    decode_snapshot_provenance(data, :requested, event_id, run_id, decision_id, decision_version, occurred_at)
  end

  def decode_typed_provenance(
        @schema_version,
        :enriched,
        data,
        event_id,
        run_id,
        decision_id,
        decision_version,
        occurred_at
      ) do
    with {:ok, decision} <- Validation.fetch_map(data, "decision", :decision) do
      decision
      |> Map.put("provenance_state", Validation.get(data, :provenance_state))
      |> Map.put("provenance_hash", Validation.get(data, :provenance_hash))
      |> decode_snapshot_provenance(:enriched, event_id, run_id, decision_id, decision_version, occurred_at)
    end
  end

  def decode_typed_provenance(
        @versioned_snapshot_schema_version,
        :requested,
        data,
        _event_id,
        _run_id,
        _decision_id,
        _decision_version,
        _occurred_at
      ) do
    decode_versioned_snapshot_provenance(data)
  end

  def decode_typed_provenance(
        @versioned_snapshot_schema_version,
        :enriched,
        data,
        _event_id,
        _run_id,
        _decision_id,
        _decision_version,
        _occurred_at
      ) do
    with {:ok, decision} <- Validation.fetch_map(data, "decision", :decision) do
      decode_versioned_snapshot_provenance(
        decision
        |> Map.put("provenance_state", Validation.get(data, :provenance_state))
        |> Map.put("provenance_hash", Validation.get(data, :provenance_hash))
      )
    end
  end

  def decode_typed_provenance(
        _schema_version,
        _type,
        data,
        _event_id,
        _run_id,
        _decision_id,
        _decision_version,
        _occurred_at
      ) do
    if is_nil(Validation.get(data, :provenance)) and is_nil(Validation.get(data, :provenance_hash)),
      do: {:ok, nil},
      else: {:error, :unexpected_provenance}
  end

  defp decode_versioned_snapshot_provenance(raw) do
    case {Validation.get(raw, :provenance_state), Validation.get(raw, :provenance), Validation.get(raw, :provenance_hash)} do
      {nil, _provenance, _hash} ->
        {:error, :provenance_state_missing}

      {"unknown", nil, nil} ->
        {:ok, nil}

      {"captured", nil, nil} ->
        {:error, :provenance_missing}

      {"captured", provenance, nil} when is_map(provenance) ->
        DecisionProvenance.from_json_safe(provenance)

      {state, _provenance, _hash} when state in ["captured", "unknown"] ->
        {:error, :invalid_provenance_state}

      _other ->
        {:error, :invalid_provenance_state}
    end
  end

  defp decode_snapshot_provenance(raw, type, event_id, run_id, decision_id, decision_version, occurred_at) do
    context = %{
      type: type,
      event_id: event_id,
      run_id: run_id,
      decision_id: decision_id,
      decision_version: decision_version,
      occurred_at: occurred_at
    }

    case snapshot_event_id_status(context.event_id) do
      :marked ->
        decode_marked_snapshot_provenance(raw, context)

      :malformed_marker ->
        {:error, :invalid_provenance_event_id}

      :legacy ->
        decode_legacy_or_bound_snapshot_provenance(raw, context)
    end
  end

  defp decode_marked_snapshot_provenance(raw, context) do
    case {Validation.get(raw, :provenance_state), Validation.get(raw, :provenance), Validation.get(raw, :provenance_hash)} do
      {"captured", provenance, hash} ->
        decode_bound_snapshot_provenance(provenance, hash, "captured", context)

      {"unknown", nil, hash} ->
        decode_bound_snapshot_provenance(nil, hash, "unknown", context)

      {nil, nil, nil} ->
        {:error, :provenance_binding_missing}

      {nil, nil, _hash} ->
        {:error, :provenance_state_missing}

      {_state, _provenance, _hash} ->
        {:error, :invalid_provenance_binding}
    end
  end

  defp decode_legacy_or_bound_snapshot_provenance(raw, context) do
    case {Validation.get(raw, :provenance_state), Validation.get(raw, :provenance), Validation.get(raw, :provenance_hash)} do
      {nil, nil, nil} ->
        {:ok, nil}

      {nil, nil, _hash} ->
        {:error, :provenance_state_missing}

      {nil, provenance, hash} ->
        decode_legacy_snapshot_provenance(provenance, hash, context)

      {"captured", provenance, hash} ->
        decode_bound_snapshot_provenance(provenance, hash, "captured", context)

      {"unknown", nil, hash} ->
        decode_bound_snapshot_provenance(nil, hash, "unknown", context)

      {_state, _provenance, _hash} ->
        {:error, :invalid_provenance_binding}
    end
  end

  defp decode_legacy_snapshot_provenance(nil, _hash, _context),
    do: {:error, :provenance_hash_without_provenance}

  defp decode_legacy_snapshot_provenance(_provenance, nil, _context),
    do: {:error, :provenance_hash_missing}

  defp decode_legacy_snapshot_provenance(provenance, hash, context)
       when is_map(provenance) and is_binary(hash) and hash != "" do
    with {:ok, provenance} <- DecisionProvenance.from_json_safe(provenance),
         :ok <- verify_provenance_hash(context, provenance, nil, hash) do
      {:ok, provenance}
    end
  end

  defp decode_legacy_snapshot_provenance(_provenance, _hash, _context),
    do: {:error, :invalid_provenance_binding}

  defp decode_bound_snapshot_provenance(nil, _hash, "captured", _context),
    do: {:error, :provenance_missing}

  defp decode_bound_snapshot_provenance(provenance, hash, state, context)
       when state == "captured" and is_map(provenance) and is_binary(hash) and hash != "" do
    with {:ok, provenance} <- DecisionProvenance.from_json_safe(provenance),
         :ok <- verify_provenance_hash(context, provenance, state, hash) do
      {:ok, provenance}
    end
  end

  defp decode_bound_snapshot_provenance(nil, hash, "unknown", context)
       when is_binary(hash) and hash != "" do
    with :ok <- verify_provenance_hash(context, nil, "unknown", hash) do
      {:ok, nil}
    end
  end

  defp decode_bound_snapshot_provenance(_provenance, _hash, _state, _context),
    do: {:error, :invalid_provenance_binding}

  defp verify_provenance_hash(context, provenance, state, persisted_hash) do
    actual_hash =
      DecisionValidation.content_hash(
        %{
          schema_version: @schema_version,
          event_type: context.type,
          event_id: context.event_id,
          run_id: context.run_id,
          decision_id: context.decision_id,
          decision_version: context.decision_version,
          occurred_at: DateTime.to_iso8601(context.occurred_at),
          provenance: provenance && DecisionProvenance.to_json_safe(provenance)
        }
        |> maybe_put_provenance_state(state)
      )

    if actual_hash == persisted_hash, do: :ok, else: {:error, :provenance_hash_mismatch}
  end

  @spec provenance_event_id(term()) :: String.t()
  def provenance_event_id(reserved_id), do: @provenance_event_id_prefix <> Integer.to_string(reserved_id)

  defp snapshot_event_id_status(event_id) when is_binary(event_id) do
    cond do
      match?({:ok, _reserved_id}, parse_provenance_event_id(event_id)) -> :marked
      String.starts_with?(event_id, @provenance_event_id_prefix) -> :malformed_marker
      true -> :legacy
    end
  end

  defp snapshot_event_id_status(_event_id), do: :legacy

  @doc false
  @spec parse_provenance_event_id(term()) :: {:ok, pos_integer()} | :error
  def parse_provenance_event_id(@provenance_event_id_prefix <> reserved_id) do
    case Integer.parse(reserved_id) do
      {value, ""} when value > 0 -> if reserved_id == Integer.to_string(value), do: {:ok, value}, else: :error
      _other -> :error
    end
  end

  def parse_provenance_event_id(_event_id), do: :error
end
