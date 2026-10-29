defmodule AiurWeb.VoiceConversationEvents do
  @moduledoc """
  Validates the mic choice handoff before assigning the MP-E6 panel request.
  Opening carries only a target and surface; capture and consent belong to
  the panel's Start action. No session or agent context is created here.
  """

  import Phoenix.Component, only: [assign: 2]

  alias AiurWeb.{DashboardLive.Voice, VoiceJoinPayload, VoiceTargets}

  @spec open(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def open(socket, params) do
    with {:ok, %{target: target, surface: surface}} <- parse(params),
         :ok <- VoiceTargets.validate(target, surface),
         :ok <- available() do
      assign(socket, voice_conversation_panel: %{target: target, surface: surface}, voice_conversation_error: nil)
    else
      {:error, refusal} -> assign(socket, voice_conversation_panel: nil, voice_conversation_error: refusal)
    end
  end

  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket), do: assign(socket, voice_conversation_panel: nil, voice_conversation_error: nil)

  defp parse(%{"surface" => surface, "target" => json}) when surface in ["agent_composer", "executor_composer"] and is_binary(json) and byte_size(json) <= 2048 do
    # Reuse the strict wire target parser used by Dictate, including its
    # field limits and closed set of fields. This does not join a channel.
    with {:ok, target} <- Jason.decode(json),
         {:ok, parsed} <- VoiceJoinPayload.parse(%{"v" => 1, "mode" => "dictate", "surface" => surface, "target" => target, "client_session_id" => "handoff"}) do
      {:ok, parsed}
    else
      _invalid -> invalid()
    end
  end

  defp parse(_params), do: invalid()
  defp invalid, do: {:error, %{reason_code: "invalid_payload", reason: "Voice request is invalid."}}

  defp available do
    case Voice.capabilities()["voice.conversation"] do
      %{state: state} when state in [:available, :degraded, "available", "degraded"] -> :ok
      %{reason: reason} -> {:error, capability_refusal(reason)}
      _unknown -> {:error, capability_refusal(:unknown)}
    end
  end

  defp capability_refusal(reason) when reason in [:not_installed, "not_installed"],
    do: %{reason_code: "not_installed", reason: "Converse isn't installed in this Aiur. Typed messages work as usual."}

  defp capability_refusal(reason) when reason in [:disabled, "disabled"],
    do: %{reason_code: "disabled", reason: "Converse is disabled."}

  defp capability_refusal(reason) when reason in [:not_configured, "not_configured"],
    do: %{reason_code: "not_configured", reason: "Converse is not configured."}

  defp capability_refusal(reason), do: %{reason_code: "unknown", reason: "Converse availability could not be checked. Try again shortly.", reasons: [reason]}
end
