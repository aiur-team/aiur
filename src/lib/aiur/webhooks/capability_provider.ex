defmodule Aiur.Webhooks.CapabilityProvider do
  @moduledoc "Read-only proven webhook delivery availability for the configured repository."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider

  alias Aiur.Webhooks.{DeliveryMode, ModeTable}

  @impl true
  def capability_ids, do: ["webhook_ingress"]

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []) do
    %{"webhook_ingress" => ingress(context.settings, opts)}
  end

  defp ingress(:unavailable, _opts), do: %{state: :unknown, reason: :unknown}

  defp ingress(%{tracker: %{kind: "github", github: %{repo: repo}}}, opts) do
    repo |> Keyword.get(opts, :mode_fun, &ModeTable.mode/1).() |> mode()
  end

  defp ingress(_settings, _opts), do: %{state: :unavailable, reason: :not_configured}

  defp mode(nil), do: %{state: :unavailable, reason: :not_configured}
  defp mode(%DeliveryMode{state: :never_configured}), do: %{state: :unavailable, reason: :not_configured}
  defp mode(%DeliveryMode{state: :configured_unproven}), do: %{state: :degraded, reason: :unknown}
  defp mode(%DeliveryMode{state: :degraded}), do: %{state: :degraded, reason: :not_running}
  defp mode(%DeliveryMode{state: :webhook_backed}), do: %{state: :available}
  defp mode(_mode), do: %{state: :unknown, reason: :unknown}
end
