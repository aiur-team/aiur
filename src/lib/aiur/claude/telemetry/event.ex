defmodule Aiur.Claude.Telemetry.Event do
  @moduledoc false

  @max_resource_logs 4
  @max_scope_logs 4
  @max_log_records 32
  @max_attributes 24
  @max_attribute_key_bytes 96
  @max_attribute_value_bytes 256

  @allowed_attributes ~w(
    event.name
    session.id
    event.sequence
    request_id
    model
    input_tokens
    output_tokens
    cache_read_tokens
    cache_creation_tokens
  )

  @type t :: %{
          event: :api_request,
          source_version: String.t(),
          transport: :otlp_http_json,
          identity: {:request | :sequence, String.t() | non_neg_integer()},
          correlation: map(),
          attributes: map()
        }

  @spec from_otlp(map(), map()) :: {:ok, [t(), ...]} | {:error, atom()}
  def from_otlp(%{"resourceLogs" => resource_logs}, correlation) when is_map(correlation) do
    with {:ok, resource_logs} <- bounded_list(resource_logs, @max_resource_logs),
         {:ok, records} <- records(resource_logs),
         {:ok, records} <- api_requests(records),
         {:ok, events} <- normalize_records(records, correlation) do
      {:ok, events}
    end
  end

  def from_otlp(_payload, _correlation), do: {:error, :malformed}

  @spec replay_key(t()) :: {String.t(), String.t(), {:request | :sequence, String.t() | non_neg_integer()}}
  def replay_key(%{source_version: version, correlation: %{session_id: session_id}, identity: identity}), do: {version, session_id, identity}

  defp records(resource_logs) do
    Enum.reduce_while(resource_logs, {:ok, []}, fn resource_log, {:ok, acc} ->
      with {:ok, resource_attributes} <- attributes_at(resource_log, "resource"),
           {:ok, scope_logs} <- bounded_list(Map.get(resource_log, "scopeLogs"), @max_scope_logs),
           {:ok, next} <- scope_records(scope_logs, resource_attributes) do
        records = acc ++ next

        if length(records) <= @max_log_records do
          {:cont, {:ok, records}}
        else
          {:halt, {:error, :attribute_limit}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
      with {:ok, attributes} <- attributes_at(record, nil) do
        {:cont, {:ok, [%{record: record, attributes: parent_attributes ++ attributes} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
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

  defp normalize_records(records, correlation) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, events} ->
      with {:ok, attributes} <- normalize_attributes(record),
           :ok <- required_attributes(attributes) do
        session_id = attributes["session.id"]
        identity = identity(attributes)

        event = %{
          event: :api_request,
          source_version: Aiur.Claude.Telemetry.source_version(),
          transport: :otlp_http_json,
          identity: identity,
          correlation: Map.put(correlation, :session_id, session_id),
          attributes: Map.take(attributes, ~w(model input_tokens output_tokens cache_read_tokens cache_creation_tokens request_id event.sequence))
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

  defp normalize_attributes(%{attributes: attributes}) do
    with :ok <- attribute_count(attributes) do
      Enum.reduce_while(attributes, {:ok, %{}}, fn attribute, {:ok, acc} ->
        case normalized_attribute(attribute) do
          :drop -> {:cont, {:ok, acc}}
          {:ok, {key, value}} -> {:cont, {:ok, Map.put(acc, key, value)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp required_attributes(attributes) do
    cond do
      not valid_identifier?(attributes["session.id"]) -> {:error, :malformed}
      not valid_identifier?(attributes["request_id"] || attributes["event.sequence"]) -> {:error, :malformed}
      not valid_nonnegative?(attributes, "input_tokens") -> {:error, :malformed}
      not valid_nonnegative?(attributes, "output_tokens") -> {:error, :malformed}
      true -> :ok
    end
  end

  defp normalized_attribute(%{"key" => key, "value" => value}) when is_binary(key) do
    cond do
      byte_size(key) > @max_attribute_key_bytes -> {:error, :attribute_limit}
      not bounded_value?(value) -> {:error, :attribute_limit}
      key not in @allowed_attributes -> :drop
      true -> normalize_value(key, value)
    end
  end

  defp normalized_attribute(_attribute), do: {:error, :malformed}

  defp normalize_value(key, %{"stringValue" => value}) when is_binary(value) and byte_size(value) <= @max_attribute_value_bytes,
    do: {:ok, {key, value}}

  defp normalize_value(key, %{"intValue" => value}) when key in ~w(input_tokens output_tokens cache_read_tokens cache_creation_tokens event.sequence) do
    case integer_string(value) do
      {:ok, integer} -> {:ok, {key, integer}}
      :error -> {:error, :malformed}
    end
  end

  defp normalize_value(_key, _value), do: {:error, :malformed}

  defp attributes_at(record, parent) when is_map(record) do
    node = if is_nil(parent), do: record, else: Map.get(record, parent, %{})
    bounded_list(Map.get(node, "attributes", []), @max_attributes)
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

  defp api_request_body?(%{"stringValue" => "claude_code.api_request"}), do: true
  defp api_request_body?(_body), do: false
  defp bounded_list(value, max) when is_list(value) and length(value) <= max, do: {:ok, value}
  defp bounded_list(_value, _max), do: {:error, :attribute_limit}

  defp bounded_value?(%{"stringValue" => value}) when is_binary(value), do: byte_size(value) <= @max_attribute_value_bytes
  defp bounded_value?(%{"intValue" => value}), do: integer_string(value) != :error
  defp bounded_value?(%{"boolValue" => value}), do: is_boolean(value)
  defp bounded_value?(%{"doubleValue" => value}), do: is_number(value)

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

  defp integer_string(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp integer_string(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp integer_string(_value), do: :error
  defp valid_identifier?(value) when is_binary(value), do: byte_size(value) in 1..@max_attribute_value_bytes
  defp valid_identifier?(value) when is_integer(value), do: value >= 0
  defp valid_identifier?(_value), do: false
  defp valid_nonnegative?(attributes, key), do: is_nil(attributes[key]) or (is_integer(attributes[key]) and attributes[key] >= 0)
end
