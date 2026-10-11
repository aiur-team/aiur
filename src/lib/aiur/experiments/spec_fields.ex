defmodule Aiur.Experiments.SpecFields do
  @moduledoc false
  @spec error(String.t(), String.t()) :: map()
  def error(path, message), do: %{path: path, message: message}

  @spec object(term(), [String.t()], String.t(), [String.t()] | nil) :: [map()]
  def object(value, keys, path, required \\ nil)

  def object(value, keys, path, required) when is_map(value) do
    Enum.map(Map.keys(value) -- keys, &error(join(path, &1), "unknown field")) ++
      Enum.flat_map(required || keys, fn key -> if Map.has_key?(value, key), do: [], else: [error(join(path, key), "is required")] end)
  end

  def object(_, _, path, _), do: [error(path, "must be an object")]

  @spec field(term(), String.t(), (term() -> boolean()), String.t(), String.t()) :: [map()]
  def field(map, key, valid?, message, prefix \\ "") do
    value = if is_map(map), do: map[key], else: nil
    if valid?.(value), do: [], else: [error(join(prefix, key), message)]
  end

  @spec timestamp?(term()) :: boolean()
  def timestamp?(value) when is_binary(value), do: match?({:ok, _, _}, DateTime.from_iso8601(value))
  def timestamp?(_), do: false

  @spec optional_timestamp?(term()) :: boolean()
  def optional_timestamp?(value), do: is_nil(value) or timestamp?(value)

  @spec text?(term()) :: boolean()
  def text?(value), do: is_binary(value) and String.length(value) > 0

  @spec positive?(term()) :: boolean()
  def positive?(value), do: is_integer(value) and value > 0

  @spec probability?(term()) :: boolean()
  def probability?(value), do: is_number(value) and value > 0 and value < 1
  defp join("", key), do: key
  defp join(path, key), do: path <> "." <> key
end
