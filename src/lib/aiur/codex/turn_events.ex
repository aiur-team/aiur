defmodule Aiur.Codex.TurnEvents do
  @moduledoc """
  Per-message metadata and event envelope construction for Codex app-server turns.
  """

  alias Aiur.Codex.AppServerPort

  @spec metadata_from_message(port(), term()) :: map()
  def metadata_from_message(port, payload) do
    port |> AppServerPort.port_metadata() |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata
end
