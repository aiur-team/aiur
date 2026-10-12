defmodule Aiur.ProviderMeterProjection.CapabilityProvider do
  @moduledoc "Read-only provider meter process and credential presence."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ["accounting.meters"]

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(_context, opts \\ []) do
    lookup = Keyword.get(opts, :lookup_fun, &Process.whereis/1)
    %{"accounting.meters" => meters(lookup.(Aiur.ProviderMeterProjection), opts)}
  end

  defp meters(nil, _opts), do: %{state: :unavailable, reason: :not_running}

  defp meters(_pid, opts) do
    env = Keyword.get(opts, :env_fun, &System.get_env/1)
    configured? = Enum.any?(~w(MOONSHOT_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY OPENROUTER_MANAGEMENT_KEY), &Provider.present?(env.(&1)))
    if configured?, do: %{state: :available}, else: %{state: :unavailable, reason: :not_configured}
  end
end
