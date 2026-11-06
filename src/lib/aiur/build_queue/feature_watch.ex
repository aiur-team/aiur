defmodule Aiur.BuildQueue.FeatureWatch do
  @moduledoc "Subscribes the queue server to the feature registry's change broadcast."

  # A registry change is the only signal that a queued feature gained or lost a member, so the
  # server asks for a prompt reconcile when one arrives. The registry owns the topic and its
  # message shape; a registry without `subscribe/0` (a test stub) simply sends nothing. The
  # subscription belongs to the server process, so it is taken once and remembered in state.
  @spec subscribe(map()) :: map()
  def subscribe(state) do
    if Map.get(state, :feature_subscribed, false), do: state, else: subscribe_now(state)
  end

  defp subscribe_now(state) do
    registry = Map.get(state, :feature_registry, Aiur.BuildOrder.Features)

    if Process.whereis(Aiur.PubSub) != nil and Code.ensure_loaded?(registry) and function_exported?(registry, :subscribe, 0) do
      registry.subscribe()
      Map.put(state, :feature_subscribed, true)
    else
      state
    end
  end
end
