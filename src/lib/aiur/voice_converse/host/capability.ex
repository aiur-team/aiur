defmodule Aiur.VoiceConverse.Host.Capability do
  @moduledoc "Reports whether the host can offer voice conversation."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ["voice.conversation"]

  @impl true
  def capabilities(context), do: %{"voice.conversation" => evaluate(context)}

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []) do
    cond do
      Provider.http(context, opts).state != :available -> Provider.dependency("api.http")
      context.settings == :unavailable -> %{state: :unknown, reason: :unknown}
      Provider.writable(context) == false -> %{state: :unavailable, reason: :disabled}
      Provider.writable(context) == :unknown -> %{state: :unknown, reason: :unknown}
      true -> availability(Keyword.get(opts, :availability_fun, &Aiur.VoiceConversation.availability/0).(), opts)
    end
  end

  defp availability(:ok, opts) do
    if Keyword.get(opts, :running_fun, fn -> Process.whereis(Aiur.VoiceConversation.instance()) != nil end).(),
      do: %{state: :available},
      else: %{state: :unavailable, reason: :not_running}
  end

  defp availability({:unavailable, {reason, field}}, _opts), do: %{state: :unavailable, reason: reason, detail: to_string(field)}
  defp availability({:unavailable, reason}, _opts), do: %{state: :unavailable, reason: reason}
end
