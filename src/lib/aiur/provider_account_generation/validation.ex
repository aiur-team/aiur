defmodule Aiur.ProviderAccountGeneration.Validation do
  @moduledoc false

  alias Aiur.CodingAgent

  @invalidation_reasons [
    :logout,
    :credential_replaced,
    :account_replaced,
    :backend_replaced,
    :continuity_lost,
    :no_authenticated_account,
    :unsupported_auth_mode,
    :untrusted_lifecycle
  ]

  @spec scope?(atom(), atom()) :: boolean()
  def scope?(provider, backend), do: backend in policy(provider, :backends)

  @spec observation?(atom(), atom(), term(), map()) :: boolean()
  def observation?(provider, backend, binding, opts) do
    scope?(provider, backend) and is_reference(binding) and trusted_source?(provider, Map.get(opts, :source)) and
      auth_mode?(provider, Map.get(opts, :auth_mode))
  end

  @spec invalidation_reason?(term()) :: boolean()
  def invalidation_reason?(reason), do: reason in @invalidation_reasons

  @spec continuity?(map(), reference()) :: boolean()
  def continuity?(opts, previous_binding), do: Map.get(opts, :continuity) == :proven and Map.get(opts, :previous_binding) == previous_binding

  @spec same_binding_continuity?(map()) :: boolean()
  def same_binding_continuity?(opts), do: Map.get(opts, :continuity) == :proven

  defp trusted_source?(provider, source), do: source in policy(provider, :trusted_sources)
  defp auth_mode?(_provider, nil), do: true
  defp auth_mode?(provider, auth_mode), do: auth_mode in policy(provider, :auth_modes)

  defp policy(provider, key) do
    provider
    |> CodingAgent.provider_account_generation()
    |> then(&Map.get(&1 || %{}, key, []))
  end
end
