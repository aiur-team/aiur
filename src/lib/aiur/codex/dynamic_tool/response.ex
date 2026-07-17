defmodule Aiur.Codex.DynamicTool.Response do
  @moduledoc """
  Builds standard response envelopes for dynamic tool results.
  """

  @spec build(boolean(), String.t()) :: map()
  def build(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  @spec failure(map()) :: map()
  def failure(payload) do
    build(false, encode_payload(payload))
  end

  @spec encode_payload(term()) :: String.t()
  def encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  def encode_payload(payload), do: inspect(payload)

  @spec jsonable(term()) :: term()
  def jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def jsonable(%{} = value), do: Map.new(value, fn {key, item} -> {json_key(key), jsonable(item)} end)
  def jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  def jsonable(value) when is_tuple(value), do: value |> Tuple.to_list() |> jsonable()
  def jsonable(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  def jsonable(value) when is_atom(value), do: Atom.to_string(value)
  def jsonable(value), do: inspect(value)

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key)
end
