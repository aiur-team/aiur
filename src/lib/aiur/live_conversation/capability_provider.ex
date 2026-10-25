defmodule Aiur.LiveConversation.CapabilityProvider do
  @moduledoc "Read-only conversation history availability, including disk fallback."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ["conversations.read"]

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []) do
    %{"conversations.read" => conversations(Provider.http(context, opts), opts)}
  end

  defp conversations(%{state: :available}, opts) do
    lookup = Keyword.get(opts, :lookup_fun, &Process.whereis/1)
    if lookup.(Aiur.LiveConversation), do: %{state: :available}, else: %{state: :degraded, reason: :not_running}
  end

  defp conversations(_http, _opts), do: Provider.dependency("api.http")
end
