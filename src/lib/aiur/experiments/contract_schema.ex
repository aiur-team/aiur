defmodule Aiur.Experiments.ContractSchema do
  @moduledoc false

  @spec validate(term(), String.t()) :: :ok | {:error, [map()]}
  def validate(value, name) do
    path = Application.app_dir(:aiur, "priv/experiments/schema/#{name}.v1.json")
    errors = check(value, Jason.decode!(File.read!(path)), name)
    if errors == [], do: :ok, else: {:error, errors}
  end

  defp check(value, schema, path) do
    if type?(value, schema["type"]) do
      scalar(value, schema, path) ++ children(value, schema, path)
    else
      error(path, "expected #{inspect(schema["type"])}")
    end
  end

  defp type?(_value, nil), do: true
  defp type?(value, types) when is_list(types), do: Enum.any?(types, &type?(value, &1))
  defp type?(value, "object"), do: is_map(value)
  defp type?(value, "array"), do: is_list(value)
  defp type?(value, "string"), do: is_binary(value)
  defp type?(value, "number"), do: is_number(value)
  defp type?(value, "integer"), do: is_integer(value)
  defp type?(value, "boolean"), do: is_boolean(value)
  defp type?(value, "null"), do: is_nil(value)

  defp scalar(value, schema, path) do
    Enum.flat_map(schema, fn {key, limit} ->
      if valid?(key, value, limit), do: [], else: error(path, "violates #{key}: #{inspect(limit)}")
    end)
  end

  defp valid?("const", value, expected), do: value == expected
  defp valid?("enum", value, values), do: value in values
  defp valid?("minLength", value, n) when is_binary(value), do: String.length(String.trim(value)) >= n
  defp valid?("minimum", value, n) when is_number(value), do: value >= n
  defp valid?("exclusiveMinimum", value, n) when is_number(value), do: value > n
  defp valid?("exclusiveMaximum", value, n) when is_number(value), do: value < n
  defp valid?("minItems", value, n) when is_list(value), do: length(value) >= n
  defp valid?("maxItems", value, n) when is_list(value), do: length(value) <= n
  defp valid?("uniqueItems", value, true) when is_list(value), do: Enum.uniq(value) == value
  defp valid?("minProperties", value, n) when is_map(value), do: map_size(value) >= n
  defp valid?("format", value, "date-time") when is_binary(value), do: match?({:ok, _, _}, DateTime.from_iso8601(value))
  defp valid?(_key, _value, _limit), do: true

  defp children(value, schema, path) when is_map(value) do
    missing = Enum.flat_map(schema["required"] || [], fn key -> if Map.has_key?(value, key), do: [], else: error(path <> "." <> key, "is required") end)
    properties = schema["properties"] || %{}
    missing ++ Enum.flat_map(value, fn {key, item} -> property(item, Map.get(properties, key, schema["additionalProperties"]), path <> "." <> key) end)
  end

  defp children(value, %{"items" => item}, path) when is_list(value) do
    value |> Enum.with_index() |> Enum.flat_map(fn {value, index} -> check(value, item, "#{path}.#{index}") end)
  end

  defp children(_value, _schema, _path), do: []
  defp property(value, schema, path) when is_map(schema), do: check(value, schema, path)
  defp property(_value, _schema, _path), do: []
  defp error(path, message), do: [%{path: path, message: message}]
end
