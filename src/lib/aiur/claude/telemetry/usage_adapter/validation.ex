defmodule Aiur.Claude.Telemetry.UsageAdapter.Validation do
  @moduledoc false

  alias Aiur.Claude.Telemetry.Contract
  alias Aiur.TrackerIdentity

  @max_scalar_bytes 256

  @spec validate(map(), DateTime.t()) :: {:ok, map()} | {:error, atom(), atom()}
  def validate(event, ingested_at) when is_map(event) do
    with {:ok, attributes, correlation} <- structure(event, ingested_at),
         :ok <- correlation(correlation),
         :ok <- measurement(attributes, event[:occurred_at]),
         {:ok, source_event_id, request_id} <- identity(event[:identity], attributes) do
      {:ok,
       %{
         attributes: attributes,
         correlation: correlation,
         occurred_at: event[:occurred_at],
         request_id: request_id,
         source_event_id: source_event_id,
         source_sequence: attributes["event.sequence"]
       }}
    end
  end

  def validate(_event, _ingested_at), do: failure(:ambiguous_measurement_semantics, :event)

  defp structure(event, ingested_at) do
    attributes = Map.get(event, :attributes)
    correlation = Map.get(event, :correlation)

    with :ok <- exact(event[:event], :api_request, :unsupported_source_revision, :event),
         :ok <- exact(event[:source_version], Contract.source_version(), :unsupported_source_revision, :source_version),
         :ok <- exact(event[:transport], :otlp_http_json, :unsupported_source_revision, :transport),
         :ok <- map_value(attributes, :ambiguous_measurement_semantics, :attributes),
         :ok <- map_value(correlation, :missing_required_identity, :correlation),
         :ok <- utc_datetime(ingested_at, :ingested_at) do
      {:ok, attributes, correlation}
    end
  end

  defp correlation(correlation) do
    with :ok <- required_opaque(correlation[:run_id], :run_id),
         :ok <- tracker_identity(correlation[:ticket]),
         :ok <- required_opaque(correlation[:attempt_id], :attempt_id),
         :ok <- positive_integer(correlation[:worker_generation], :worker_generation),
         :ok <- required_opaque(correlation[:producer_generation], :producer_generation),
         :ok <- exact(correlation[:backend], "claude-repl", :ambiguous_measurement_semantics, :backend),
         do:
           required_value(
             correlation[:session_id],
             &Contract.valid_session_id?/1,
             :missing_required_identity,
             :session_id
           )
  end

  defp measurement(attributes, occurred_at) do
    with :ok <- nonnegative_integer(attributes["event.sequence"], :event_sequence),
         :ok <- required_value(attributes["model"], &Contract.valid_model?/1, :ambiguous_measurement_semantics, :model),
         :ok <- optional_value(attributes["request_id"], &Contract.valid_request_id?/1, :request_id),
         :ok <- nonnegative_integer(attributes["input_tokens"], :input_tokens),
         :ok <- nonnegative_integer(attributes["output_tokens"], :output_tokens),
         :ok <- optional_nonnegative_integer(attributes["cache_read_tokens"], :cache_read_tokens),
         :ok <- optional_nonnegative_integer(attributes["cache_creation_tokens"], :cache_creation_tokens),
         :ok <- optional_cost(attributes["cost_usd"]),
         :ok <- optional_value(attributes["query_source"], &Contract.valid_query_source?/1, :query_source),
         :ok <- optional_value(attributes["effort"], &Contract.valid_effort?/1, :effort),
         do: optional_occurrence(occurred_at)
  end

  defp identity({:request, request_id}, %{"request_id" => request_id}) when is_binary(request_id),
    do: {:ok, request_id, request_id}

  defp identity({:sequence, sequence}, %{"event.sequence" => sequence} = attributes)
       when is_integer(sequence) do
    if is_nil(attributes["request_id"]),
      do: {:ok, "event.sequence:#{sequence}", nil},
      else: failure(:ambiguous_measurement_semantics, :identity)
  end

  defp identity(nil, _attributes), do: failure(:missing_required_identity, :identity)
  defp identity(_identity, _attributes), do: failure(:ambiguous_measurement_semantics, :identity)

  defp exact(value, expected, _class, _field) when value == expected, do: :ok
  defp exact(_value, _expected, class, field), do: failure(class, field)

  defp map_value(value, _class, _field) when is_map(value), do: :ok
  defp map_value(_value, class, field), do: failure(class, field)

  defp required_opaque(value, field) do
    if valid_scalar?(value), do: :ok, else: failure(:missing_required_identity, field)
  end

  defp required_value(value, validator, class, field) do
    if validator.(value), do: :ok, else: failure(class, field)
  end

  defp valid_scalar?(value) when is_binary(value) and byte_size(value) in 1..@max_scalar_bytes,
    do: String.valid?(value) and value == String.trim(value)

  defp valid_scalar?(_value), do: false

  defp tracker_identity(%TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity), do: :ok, else: failure(:missing_required_identity, :ticket)
  end

  defp tracker_identity(_identity), do: failure(:missing_required_identity, :ticket)

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, field), do: failure(:missing_required_identity, field)

  defp nonnegative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok
  defp nonnegative_integer(_value, field), do: failure(:ambiguous_measurement_semantics, field)

  defp optional_nonnegative_integer(nil, _field), do: :ok
  defp optional_nonnegative_integer(value, field), do: nonnegative_integer(value, field)

  defp optional_cost(nil), do: :ok

  defp optional_cost(value) do
    case Contract.exact_cost(value) do
      {:ok, _decimal} -> :ok
      :error -> failure(:ambiguous_measurement_semantics, :cost_usd)
    end
  end

  defp optional_value(nil, _validator, _field), do: :ok

  defp optional_value(value, validator, field) do
    if validator.(value), do: :ok, else: failure(:ambiguous_measurement_semantics, field)
  end

  defp optional_occurrence(nil), do: :ok
  defp optional_occurrence(value), do: utc_datetime(value, :occurred_at)

  defp utc_datetime(%DateTime{utc_offset: 0, std_offset: 0}, _field), do: :ok
  defp utc_datetime(_value, field), do: failure(:ambiguous_measurement_semantics, field)

  defp failure(class, field), do: {:error, class, field}
end
