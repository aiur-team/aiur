defmodule Aiur.ElevenLabs.CapabilityProvider do
  @moduledoc """
  Read-only voice availability; secrets never enter the report.

  Voice is reported available only when every prerequisite for a working
  session holds: a bound listener, an installed voice provider, a nonblank key
  (and voice ID for speech), and a writable dashboard, since the voice socket
  refuses read-only dashboards.
  """
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ~w(voice.stt voice.tts)

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []) do
    stt = stt(Provider.http(context, opts), context, opts)
    %{"voice.stt" => stt, "voice.tts" => tts(stt, context.settings)}
  end

  defp stt(%{state: :available}, %{settings: :unavailable}, _opts), do: %{state: :unknown, reason: :unknown}

  defp stt(%{state: :available}, %{settings: %{elevenlabs: settings}} = context, opts) do
    cond do
      is_nil(Keyword.get(opts, :provider_fun, &Aiur.Voice.provider/0).()) -> %{state: :unavailable, reason: :not_installed}
      not Provider.present?(settings.api_key) -> %{state: :unavailable, reason: :not_configured}
      Provider.writable(context) == false -> %{state: :unavailable, reason: :disabled}
      Provider.writable(context) == :unknown -> %{state: :unknown, reason: :unknown}
      true -> %{state: :available}
    end
  end

  defp stt(_http, _context, _opts), do: Provider.dependency("api.http")

  defp tts(%{state: :available}, %{elevenlabs: settings}) do
    if Provider.present?(settings.voice_id), do: %{state: :available}, else: %{state: :unavailable, reason: :not_configured}
  end

  defp tts(stt, _settings), do: stt
end
