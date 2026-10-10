defmodule AiurWeb.StreamdeckCapabilityProvider do
  @moduledoc "Read-only daemon API availability; sidecar presence is not observed."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ["streamdeck"]

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []) do
    %{"streamdeck" => streamdeck(Provider.http(context, opts), opts)}
  end

  defp streamdeck(%{state: :available}, opts) do
    env = Keyword.get(opts, :env_fun, &System.get_env/1)
    configured? = Enum.all?(~w(AIUR_DASHBOARD_USERNAME AIUR_DASHBOARD_PASSWORD), &Provider.present?(env.(&1)))
    if configured?, do: %{state: :available}, else: %{state: :unavailable, reason: :not_configured}
  end

  defp streamdeck(_http, _opts), do: Provider.dependency("api.http")
end
