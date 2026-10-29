defmodule AiurWeb.DashboardLive.Voice do
  @moduledoc "Refreshes registry capabilities used by the Commands voice controls."

  import Phoenix.Component, only: [assign: 3]

  alias AiurWeb.EndpointConfig

  @spec assign_voice(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_voice(socket) do
    assign(socket, :voice_capabilities, capabilities())
  end

  # The same entries `/api/v1/capabilities` serves; an unreadable registry
  # leaves Commands without voice attributes rather than guessing.
  defp capabilities do
    report = (EndpointConfig.get(:capabilities_report_fun) || (&Aiur.Capabilities.report/0)).()
    report |> Map.get(:capabilities, %{}) |> Map.take(~w(voice.stt voice.tts voice.conversation))
  rescue
    _error -> %{}
  catch
    _kind, _reason -> %{}
  end
end
