defmodule Aiur.ElevenLabs.CapabilityProvider do
  @moduledoc "Read-only voice configuration availability; secrets never enter the report."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ~w(voice.stt voice.tts)

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []) do
    stt = stt(Provider.http(context, opts), context.settings)
    %{"voice.stt" => stt, "voice.tts" => tts(stt, context.settings)}
  end

  defp stt(%{state: :available}, :unavailable), do: %{state: :unknown, reason: :unknown}
  defp stt(%{state: :available}, %{elevenlabs: settings}), do: configured(settings.api_key)
  defp stt(_http, _settings), do: Provider.dependency("api.http")

  defp tts(%{state: :available}, %{elevenlabs: settings}), do: configured(settings.voice_id)
  defp tts(stt, _settings), do: stt

  defp configured(value) do
    if Provider.present?(value), do: %{state: :available}, else: %{state: :unavailable, reason: :not_configured}
  end
end
