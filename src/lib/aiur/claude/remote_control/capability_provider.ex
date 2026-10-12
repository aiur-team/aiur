defmodule Aiur.Claude.RemoteControl.CapabilityProvider do
  @moduledoc "Read-only Remote Control configuration and HTTP hook availability."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider
  alias Aiur.Config.RoutingValue

  @impl true
  def capability_ids, do: ["remote_control"]

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []) do
    %{"remote_control" => remote(context.settings, context, opts)}
  end

  defp remote(:unavailable, _context, _opts), do: %{state: :unknown, reason: :unknown}

  defp remote(%{agent: agent}, context, opts) do
    enabled? = agent.remote_control or Enum.any?(Map.values(agent.routing), &RoutingValue.routing_remote_flag?/1)

    cond do
      not enabled? -> %{state: :unavailable, reason: :disabled}
      Provider.http(context, opts).state != :available -> Provider.dependency("api.http")
      true -> %{state: :available}
    end
  end
end
