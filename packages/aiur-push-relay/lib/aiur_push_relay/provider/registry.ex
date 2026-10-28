defmodule AiurPushRelay.Provider.Registry do
  @moduledoc "Routes handles to enabled platform adapters."
  @behaviour AiurPushRelay.Provider

  @spec available?(String.t()) :: boolean()
  def available?("apns"), do: not is_nil(Process.whereis(AiurPushRelay.ApnsJwt))
  def available?(_), do: false

  @impl true
  def deliver(%{platform: "apns"} = row, envelope) do
    if available?("apns"),
      do: AiurPushRelay.Provider.Apns.deliver(row, envelope),
      else: {:error, :provider_unavailable}
  end

  def deliver(_, _), do: {:error, :provider_unavailable}
end
