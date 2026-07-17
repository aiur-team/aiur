defmodule Aiur.Claude.Telemetry.Event do
  @moduledoc false

  @max_resource_logs 4
  @max_scope_logs 4
  @max_log_records 32
  @max_attributes 24
  @max_attribute_key_bytes 96
  @max_attribute_value_bytes 256
  @max_otlp_int64 9_223_372_036_854_775_807
  @max_otlp_int64_bytes 19

  alias Aiur.Claude.Telemetry.Contract
  alias Aiur.SecretRedactor

  @source Contract.source()
  @allowed_attributes ~w(
    event.name
    session.id
    service.name
    service.version
    event.sequence
    request_id
    model
    cost_usd
    input_tokens
    output_tokens
    cache_read_tokens
    cache_creation_tokens
    query_source
    effort
  )
  @integer_attributes ~w(input_tokens output_tokens cache_read_tokens cache_creation_tokens event.sequence)

  @type t :: %{
          event: :api_request,
          source_version: String.t(),
          transport: :otlp_http_json,
          identity: {:request | :sequence, String.t() | non_neg_integer()},
          occurred_at: DateTime.t() | nil,
          correlation: map(),
          attributes: map()
        }

  @type source_contract :: %{
          required(:emitter_version) => String.t(),
          required(:forbidden_values) => [String.t()],
          required(:service_name) => String.t(),
          required(:source_version) => String.t()
        }

  @spec from_otlp(map(), map(), source_contract()) :: {:ok, [t(), ...]} | {:error, atom()}
  def from_otlp(%{"resourceLogs" => resource_logs}, correlation, source_contract)
      when is_map(correlation) and is_map(source_contract) do
    with {:ok, resource_logs} <- bounded_list(resource_logs, @max_resource_logs),
         {:ok, records} <- records(resource_logs, source_contract),
         {:ok, records} <- api_requests(records) do
      normalize_records(records, correlation, source_contract)
    end
  end

  def from_otlp(_payload, _correlation, _source_contract), do: {:error, :malformed}

  @spec replay_key(t()) :: {String.t(), String.t(), {:request | :sequence, String.t() | non_neg_integer()}}
  def replay_key(%{source_version: version, correlation: %{session_id: session_id}, identity: identity}), do: {version, session_id, identity}

  defp records(resource_logs, source_contract) do
    Enum.reduce_while(resource_logs, {:ok, []}, fn resource_log, acc ->
      append_resource_records(resource_log, acc, source_contract)
    end)
  end

  defp append_resource_records(resource_log, {:ok, acc}, source_contract) do
    with {:ok, resource_attributes} <- attributes_at(resource_log, "resource"),
         :ok <- authenticated_resource(resource_attributes, source_contract),
         {:ok, scope_logs} <- bounded_list(Map.get(resource_log, "scopeLogs"), @max_scope_logs),
         {:ok, next} <- scope_records(scope_logs, resource_attributes) do
      append_records(acc, next)
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp append_records(acc, next) do
    records = acc ++ next

    if length(records) <= @max_log_records do
      {:cont, {:ok, records}}
    else
      {:halt, {:error, :attribute_limit}}
    end
  end

  defp scope_records(scope_logs, resource_attributes) do
    Enum.reduce_while(scope_logs, {:ok, []}, fn scope_log, {:ok, acc} ->
      with {:ok, scope_attributes} <- attributes_at(scope_log, "scope"),
           {:ok, log_records} <- bounded_list(Map.get(scope_log, "logRecords"), @max_log_records),
           {:ok, next} <- record_entries(log_records, resource_attributes ++ scope_attributes) do
        {:cont, {:ok, acc ++ next}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record_entries(log_records, parent_attributes) do
    Enum.reduce_while(log_records, {:ok, []}, fn record, {:ok, acc} ->
      case attributes_at(record, nil) do
        {:ok, attributes} ->
          {:cont, {:ok, [%{record: record, attributes: parent_attributes ++ attributes} | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp api_requests(records) do
    api_requests =
      Enum.filter(records, fn %{record: record, attributes: attributes} ->
        api_request_body?(Map.get(record, "body")) and attribute_value(attributes, "event.name") == "api_request"
      end)

    if api_requests == [], do: {:error, :unsupported_event}, else: {:ok, api_requests}
  end

  defp normalize_records(records, correlation, source_contract) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, events} ->
      with {:ok, attributes} <- normalize_attributes(record, source_contract),
           :ok <- required_attributes(attributes, source_contract),
           {:ok, occurred_at} <- occurrence_time(record.record) do
        session_id = attributes["session.id"]
        identity = identity(attributes)

        event = %{
          event: :api_request,
          source_version: source_contract.source_version,
          transport: :otlp_http_json,
          identity: identity,
          occurred_at: occurred_at,
          correlation: Map.put(correlation, :session_id, session_id),
          attributes:
            Map.take(
              attributes,
              ~w(model cost_usd input_tokens output_tokens cache_read_tokens cache_creation_tokens request_id event.sequence query_source effort)
            )
        }

        {:cont, {:ok, [event | events]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp normalize_attributes(%{attributes: attributes}, source_contract) do
    with :ok <- attribute_count(attributes) do
      normalize_attribute_list(attributes, source_contract)
    end
  end

  defp normalize_attribute_list(attributes, source_contract) do
    Enum.reduce_while(attributes, {:ok, %{}}, fn attribute, {:ok, acc} ->
      case normalized_attribute(attribute, source_contract) do
        :drop -> {:cont, {:ok, acc}}
        {:ok, {key, value}} -> put_unique_attribute(acc, key, value)
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp put_unique_attribute(attributes, key, value) do
    if Map.has_key?(attributes, key),
      do: {:halt, {:error, :malformed}},
      else: {:cont, {:ok, Map.put(attributes, key, value)}}
  end

  defp required_attributes(attributes, source_contract) do
    with :ok <- source_attributes(attributes, source_contract),
         :ok <- required_string_attributes(attributes),
         do: required_integer_attributes(attributes)
  end

  defp required_string_attributes(attributes) do
    valid? =
      Enum.all?([
        attributes["event.name"] == "api_request",
        Contract.valid_session_id?(attributes["session.id"]),
        Contract.valid_model?(attributes["model"]),
        optional_source_value?(attributes["request_id"], &Contract.valid_request_id?/1),
        optional_source_value?(attributes["query_source"], &Contract.valid_query_source?/1),
        optional_source_value?(attributes["effort"], &Contract.valid_effort?/1)
      ])

    if valid?, do: :ok, else: {:error, :malformed}
  end

  defp optional_source_value?(nil, _validator), do: true
  defp optional_source_value?(value, validator), do: validator.(value)

  defp required_integer_attributes(attributes) do
    cond do
      not valid_sequence?(attributes["event.sequence"]) -> {:error, :malformed}
      not valid_nonnegative?(attributes, "input_tokens") -> {:error, :malformed}
      not valid_nonnegative?(attributes, "output_tokens") -> {:error, :malformed}
      true -> :ok
    end
  end

  defp normalized_attribute(%{"key" => key, "value" => value}, source_contract) when is_binary(key) do
    cond do
      byte_size(key) > @max_attribute_key_bytes -> {:error, :attribute_limit}
      not bounded_value?(value) -> {:error, :attribute_limit}
      key not in @allowed_attributes -> :drop
      true -> normalize_value(key, value, source_contract)
    end
  end

  defp normalized_attribute(_attribute, _source_contract), do: {:error, :malformed}

  defp normalize_value(key, %{"stringValue" => value}, source_contract)
       when is_binary(value) and byte_size(value) <= @max_attribute_value_bytes do
    with :ok <- content_free_string(value, source_contract),
         :ok <- validate_string_value(key, value, source_contract) do
      {:ok, {key, value}}
    end
  end

  defp normalize_value(key, %{"intValue" => value}, _source_contract) when key in @integer_attributes do
    case bounded_integer(value) do
      {:ok, integer} -> {:ok, {key, integer}}
      :error -> {:error, :malformed}
    end
  end

  defp normalize_value("cost_usd", %{"doubleValue" => value}, _source_contract) do
    case Contract.exact_cost(value) do
      {:ok, decimal} -> {:ok, {"cost_usd", decimal}}
      :error -> {:error, :malformed}
    end
  end

  defp normalize_value(_key, _value, _source_contract), do: {:error, :malformed}

  defp attributes_at(record, parent) when is_map(record) do
    node = if is_nil(parent), do: record, else: Map.get(record, parent, %{})

    if is_map(node) do
      bounded_list(Map.get(node, "attributes", []), @max_attributes)
    else
      {:error, :malformed}
    end
  end

  defp attributes_at(_record, _parent), do: {:error, :malformed}

  defp attribute_count(attributes) when length(attributes) <= @max_attributes, do: :ok
  defp attribute_count(_attributes), do: {:error, :attribute_limit}

  defp attribute_value(attributes, key) do
    Enum.find_value(attributes, fn
      %{"key" => ^key, "value" => %{"stringValue" => value}} when is_binary(value) -> value
      _ -> nil
    end)
  end

  defp authenticated_resource(attributes, source_contract) do
    with {:ok, service_name} <- one_string_attribute(attributes, "service.name"),
         {:ok, emitter_version} <- one_string_attribute(attributes, "service.version"),
         :ok <- content_free_string(service_name, source_contract),
         :ok <- content_free_string(emitter_version, source_contract),
         :ok <- validate_string_value("service.name", service_name, source_contract),
         :ok <- validate_string_value("service.version", emitter_version, source_contract) do
      :ok
    else
      _ -> {:error, :unsupported_version}
    end
  end

  defp one_string_attribute(attributes, key) do
    values =
      Enum.flat_map(attributes, fn
        %{"key" => ^key, "value" => %{"stringValue" => value}} when is_binary(value) -> [value]
        _attribute -> []
      end)

    case values do
      [value] -> {:ok, value}
      _values -> {:error, :unsupported_version}
    end
  end

  defp api_request_body?(%{"stringValue" => @source}), do: true
  defp api_request_body?(_body), do: false
  defp bounded_list(value, max) when is_list(value) and length(value) <= max, do: {:ok, value}
  defp bounded_list(_value, _max), do: {:error, :attribute_limit}

  defp bounded_value?(%{"stringValue" => value}) when is_binary(value), do: byte_size(value) <= @max_attribute_value_bytes
  defp bounded_value?(%{"intValue" => value}), do: bounded_integer(value) != :error
  defp bounded_value?(%{"boolValue" => value}), do: is_boolean(value)
  defp bounded_value?(%{"doubleValue" => %Decimal{} = value}), do: Contract.bounded_decimal?(value)
  defp bounded_value?(%{"doubleValue" => value}) when is_number(value), do: true
  defp bounded_value?(%{"doubleValue" => value}) when is_binary(value), do: byte_size(value) <= @max_attribute_value_bytes

  defp bounded_value?(%{"arrayValue" => %{"values" => values}}) when is_list(values) and length(values) <= 8 do
    Enum.all?(values, &bounded_value?/1)
  end

  defp bounded_value?(_value), do: false

  defp identity(attributes) do
    case attributes["request_id"] do
      value when is_binary(value) -> {:request, value}
      _ -> {:sequence, attributes["event.sequence"]}
    end
  end

  defp occurrence_time(record) when is_map(record) do
    case Map.fetch(record, "timeUnixNano") do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        with {:ok, nanoseconds} <- bounded_integer(value),
             {:ok, occurred_at} <- DateTime.from_unix(nanoseconds, :nanosecond) do
          {:ok, occurred_at}
        else
          _ -> {:error, :malformed}
        end
    end
  end

  defp occurrence_time(_record), do: {:error, :malformed}

  defp bounded_integer(value) when is_integer(value) and value in 0..@max_otlp_int64, do: {:ok, value}

  defp bounded_integer(value) when is_binary(value) and byte_size(value) <= @max_otlp_int64_bytes do
    case Integer.parse(value) do
      {integer, ""} when integer in 0..@max_otlp_int64 -> {:ok, integer}
      _ -> :error
    end
  end

  defp bounded_integer(_value), do: :error

  defp content_free_string(value, %{forbidden_values: forbidden_values}) when is_list(forbidden_values) do
    cond do
      not String.valid?(value) -> {:error, :malformed}
      SecretRedactor.redact(value) != value -> {:error, :malformed}
      value in forbidden_values -> {:error, :malformed}
      true -> :ok
    end
  end

  defp content_free_string(_value, _source_contract), do: {:error, :unsupported_version}

  defp validate_string_value("event.name", "api_request", _source_contract), do: :ok
  defp validate_string_value("session.id", value, _source_contract), do: if(Contract.valid_session_id?(value), do: :ok, else: {:error, :malformed})
  defp validate_string_value("request_id", value, _source_contract), do: if(Contract.valid_request_id?(value), do: :ok, else: {:error, :malformed})
  defp validate_string_value("model", value, _source_contract), do: if(Contract.valid_model?(value), do: :ok, else: {:error, :malformed})
  defp validate_string_value("query_source", value, _source_contract), do: if(Contract.valid_query_source?(value), do: :ok, else: {:error, :malformed})
  defp validate_string_value("effort", value, _source_contract), do: if(Contract.valid_effort?(value), do: :ok, else: {:error, :malformed})
  defp validate_string_value("service.name", value, %{service_name: value}), do: :ok
  defp validate_string_value("service.name", _value, _source_contract), do: {:error, :unsupported_version}
  defp validate_string_value("service.version", value, %{emitter_version: value}), do: :ok
  defp validate_string_value("service.version", _value, _source_contract), do: {:error, :unsupported_version}
  defp validate_string_value(_key, _value, _source_contract), do: {:error, :malformed}

  defp source_attributes(attributes, %{service_name: service_name, emitter_version: emitter_version}) do
    if attributes["service.name"] == service_name and attributes["service.version"] == emitter_version,
      do: :ok,
      else: {:error, :unsupported_version}
  end

  defp source_attributes(_attributes, _source_contract), do: {:error, :unsupported_version}
  defp valid_sequence?(value), do: is_integer(value) and value in 0..@max_otlp_int64
  defp valid_nonnegative?(attributes, key), do: is_nil(attributes[key]) or (is_integer(attributes[key]) and attributes[key] >= 0)
end
