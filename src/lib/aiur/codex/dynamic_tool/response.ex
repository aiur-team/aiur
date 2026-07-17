defmodule Aiur.Codex.DynamicTool.Response do
  @moduledoc """
  Builds standard response envelopes for dynamic tool results.
  """

  alias Aiur.JSONSafe

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
  defdelegate jsonable(value), to: JSONSafe, as: :normalize
end
