defmodule Aiur.HttpServer.CapabilityProvider do
  @moduledoc "Read-only HTTP listener availability."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ["api.http"]

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []), do: %{"api.http" => Provider.http(context, opts)}
end
