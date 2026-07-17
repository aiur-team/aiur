defmodule Aiur.ProviderAccountGeneration.Validation do
  @moduledoc false

  @trusted_sources %{codex: [:codex_app_server], claude: [:claude_app_server]}
  @auth_modes ~w(apikey chatgpt chatgptAuthTokens headers agentIdentity personalAccessToken bedrockApiKey subscription api_key)
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
  def scope?(provider, :app_server), do: provider in [:codex, :claude]
  def scope?(_provider, _backend), do: false

  @spec observation?(atom(), atom(), term(), map()) :: boolean()
  def observation?(provider, backend, binding, opts) do
    scope?(provider, backend) and is_reference(binding) and trusted_source?(provider, Map.get(opts, :source)) and auth_mode?(Map.get(opts, :auth_mode))
  end

  @spec invalidation_reason?(term()) :: boolean()
  def invalidation_reason?(reason), do: reason in @invalidation_reasons

  @spec continuity?(map(), reference()) :: boolean()
  def continuity?(opts, previous_binding), do: Map.get(opts, :continuity) == :proven and Map.get(opts, :previous_binding) == previous_binding

  @spec same_binding_continuity?(map()) :: boolean()
  def same_binding_continuity?(opts), do: Map.get(opts, :continuity) == :proven

  defp trusted_source?(provider, source), do: source in Map.get(@trusted_sources, provider, [])
  defp auth_mode?(nil), do: true
  defp auth_mode?(auth_mode), do: auth_mode in @auth_modes
end
