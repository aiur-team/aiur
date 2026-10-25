defmodule Aiur.Capabilities.IdentityProvider do
  @moduledoc "Identity's contribution to the registry."
  @behaviour Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ["identity"]

  @impl true
  def capabilities(_context), do: %{"identity" => Aiur.Identity.identity_capability()}
end
