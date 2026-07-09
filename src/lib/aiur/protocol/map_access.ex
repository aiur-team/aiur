defmodule Aiur.Protocol.MapAccess do
  @moduledoc """
  Shared atom/string-tolerant access helpers for protocol maps.
  """

  @spec get(term(), atom()) :: term()
  # Tolerate both atom- and binary-keyed maps. Codex notifications arrive
  # as string-keyed JSON; internal aiur messages stay atom-keyed.
  def get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  def get(_map, _key), do: nil

  @spec dig(term(), [term()]) :: term()
  def dig(map, []), do: map

  def dig(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      value -> dig(value, rest)
    end
  end

  def dig(_, _), do: nil

  @spec notification_method(map()) :: term()
  def notification_method(message) do
    case get(message, :payload) do
      payload when is_map(payload) -> get(payload, :method)
      _ -> nil
    end
  end

  @spec notification_item(map()) :: term()
  def notification_item(message) do
    with payload when is_map(payload) <- get(message, :payload),
         params when is_map(params) <- get(payload, :params) do
      get(params, :item)
    else
      _ -> nil
    end
  end

  @spec params_turn_id(map(), atom()) :: String.t() | nil
  def params_turn_id(message, key) do
    with payload when is_map(payload) <- get(message, :payload),
         params when is_map(params) <- get(payload, :params),
         id when is_binary(id) and id != "" <- get(params, key) do
      id
    else
      _ -> nil
    end
  end

  @spec message_timestamp(map()) :: DateTime.t()
  def message_timestamp(message) do
    case Map.get(message, :timestamp) || Map.get(message, "timestamp") do
      %DateTime{} = ts -> ts
      _ -> DateTime.utc_now()
    end
  end
end
