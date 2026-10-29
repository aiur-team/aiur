defmodule AiurWeb.DashboardLive.Voice do
  @moduledoc """
  Voice assigns refreshed at mount and on the 60 s voice tick: the provider's
  quota snapshot and the `voice.stt`/`voice.tts`/`voice.conversation` registry entries, so the drawer
  can tell "not configured" from "failed" before the microphone is pressed.
  """

  import Phoenix.Component, only: [assign: 3]

  alias AiurWeb.EndpointConfig

  @spec assign_voice(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_voice(socket) do
    socket
    |> assign(:elevenlabs_quota, Aiur.Voice.quota_snapshot())
    |> assign(:voice_capabilities, capabilities())
  end

  # The same entries `/api/v1/capabilities` serves; an unreadable registry
  # leaves the drawer without voice attributes rather than guessing.
  @doc false
  @spec capabilities() :: map()
  def capabilities do
    report = (EndpointConfig.get(:capabilities_report_fun) || (&Aiur.Capabilities.report/0)).()
    capabilities = report |> Map.get(:capabilities, %{}) |> Map.take(~w(voice.stt voice.tts voice.conversation))

    # The host may be installed before the dashboard panel. Do not offer an
    # action whose panel consumer has not shipped (MP-E6-C7-T02).
    panel = EndpointConfig.get(:voice_conversation_panel_module, AiurWeb.Components.ConversePanel)

    if Map.has_key?(capabilities, "voice.conversation") and not Code.ensure_loaded?(panel),
      do: Map.put(capabilities, "voice.conversation", %{state: :unavailable, reason: :not_installed}),
      else: capabilities
  rescue
    _error -> %{}
  catch
    _kind, _reason -> %{}
  end
end
