defmodule Aiur.Config.Schema.Attrs do
  @moduledoc "Pre-cast raw-config preprocessing: deep key stringification and nil-dropping with preserved agent load-control nulls."

  @spec normalize_keys(map() | list() | term()) :: map() | list() | term()
  def normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  def normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  def normalize_keys(value), do: value

  @spec normalize_optional_map(nil | map()) :: nil | map()
  def normalize_optional_map(nil), do: nil
  def normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  @spec normalize_key(atom() | term()) :: String.t()
  def normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  def normalize_key(value), do: to_string(value)

  @spec drop_nil_values(map() | list() | term()) :: map() | list() | term()
  def drop_nil_values(value), do: drop_nil_values(value, [])

  @spec drop_nil_values(map() | list() | term(), list()) :: map() | list() | term()
  def drop_nil_values(value, path) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      child_path = path ++ [key]

      case drop_nil_values(nested, child_path) do
        nil ->
          put_preserved_nil(acc, key, child_path)

        normalized ->
          Map.put(acc, key, normalized)
      end
    end)
  end

  def drop_nil_values(value, path) when is_list(value),
    do: Enum.map(value, &drop_nil_values(&1, path))

  def drop_nil_values(value, _path), do: value

  @spec put_preserved_nil(map(), term(), list()) :: map()
  def put_preserved_nil(acc, key, path) do
    if preserve_nil_path?(path), do: Map.put(acc, key, nil), else: acc
  end

  # max_load_average defaults to 1.5 (gate on), so an explicit YAML null is the
  # only way to disable the gate. Without this, drop_nil_values/2 would strip the
  # null before the changeset, letting the default silently re-enable the gate.
  # Keep this path aligned with the Agent schema field's location.
  @spec preserve_nil_path?(list()) :: boolean()
  def preserve_nil_path?(["agent", "max_load_average"]), do: true
  def preserve_nil_path?(["agent", "target_load_average"]), do: true
  def preserve_nil_path?(_path), do: false
end
