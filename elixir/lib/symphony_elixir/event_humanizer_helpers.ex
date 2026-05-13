defmodule SymphonyElixir.EventHumanizerHelpers do
  @moduledoc false

  @spec map_path(term(), [term()]) :: term()
  def map_path(data, [key | rest]) when is_map(data) do
    case fetch_map_key(data, key) do
      {:ok, value} when rest == [] -> value
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  def map_path(_data, _path), do: nil

  @spec map_value(map(), [term()]) :: term()
  def map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  def map_value(_map, _keys), do: nil

  @spec inline_text(term()) :: String.t()
  def inline_text(text) when is_binary(text) do
    text
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(80)
  end

  def inline_text(other), do: other |> to_string() |> inline_text()

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(value, max) when byte_size(value) > max do
    value |> String.slice(0, max) |> Kernel.<>("...")
  end

  def truncate(value, _max), do: value

  @spec humanize_item_type(term()) :: String.t()
  def humanize_item_type(nil), do: "item"

  def humanize_item_type(type) when is_binary(type) do
    type
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.replace("_", " ")
    |> String.replace("/", " ")
    |> String.downcase()
    |> String.trim()
  end

  def humanize_item_type(type), do: to_string(type)

  @spec short_id(term()) :: String.t() | nil
  def short_id(id) when is_binary(id) and byte_size(id) > 12, do: String.slice(id, 0, 12)
  def short_id(id) when is_binary(id), do: id
  def short_id(_id), do: nil

  @spec format_count(term()) :: String.t()
  def format_count(nil), do: "0"

  def format_count(value) when is_integer(value) do
    cond do
      value >= 1_000_000 -> "#{Float.round(value / 1_000_000, 1)}M"
      value >= 1_000 -> "#{Float.round(value / 1_000, 1)}K"
      true -> to_string(value)
    end
  end

  def format_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> format_count(parsed)
      _ -> value
    end
  end

  def format_count(value), do: to_string(value)

  @spec parse_integer(term()) :: integer() | nil
  def parse_integer(value) when is_integer(value), do: value

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  def parse_integer(_value), do: nil

  defp fetch_map_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        alternate = alternate_key(key)

        if alternate == key do
          :error
        else
          Map.fetch(map, alternate)
        end
    end
  end

  defp alternate_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp alternate_key(key) when is_atom(key), do: Atom.to_string(key)
  defp alternate_key(key), do: key
end
