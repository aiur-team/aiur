defmodule Aiur.VoiceConverse.Host.Config do
  @moduledoc "Maps Aiur's resolved voice settings into a conversation instance."

  alias Aiur.Config.Paths
  alias Aiur.VoiceConversation.Provider
  alias Aiur.VoiceConverse.Host.{AgentChannel, BriefingSource, CommandSource, Credentials}

  @limit_keys [:max_session_seconds, :idle_timeout_seconds, :daily_minutes_cap, :context_token_budget]

  @spec build(map()) :: {:ok, VoiceConverse.Config.t()} | {:error, term()}
  def build(settings) do
    with {:ok, root} <- Paths.voice_conversation_state_dir() do
      build(settings, root)
    end
  end

  @spec build!(map()) :: VoiceConverse.Config.t()
  def build!(settings) do
    case build(settings) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid voice conversation configuration: #{inspect(reason)}"
    end
  end

  @spec build(map(), Path.t()) :: {:ok, VoiceConverse.Config.t()} | {:error, term()}
  def build(settings, transcript_root) do
    VoiceConverse.Config.new(
      name: Aiur.VoiceConversation.Instance,
      provider: provider(settings),
      credentials: Credentials,
      briefing_source: BriefingSource,
      command_source: CommandSource,
      agent_channel: AgentChannel,
      transcript_root: transcript_root,
      llm: settings.llm,
      cloud_disclosure_accepted: settings.cloud_disclosure_accepted,
      roles_dir: settings.roles_dir,
      redactor: &redact/1,
      limits: Map.take(settings, @limit_keys),
      allowed_tools: ["get_status", "get_details", "record_summary", "end_conversation"]
    )
  end

  defp redact(text), do: text |> VoiceConverse.Redact.redact() |> Aiur.SecretRedactor.redact() |> Aiur.SecretRedactor.redact_urls()
  defp provider(%{provider: :openai_realtime} = settings), do: {Aiur.VoiceConversation.OpenAIProvider, [voice_id: settings.voice_id]}
  defp provider(%{agent_id: nil}), do: nil
  defp provider(%{agent_id: agent_id}), do: {Provider, [agent_id: agent_id]}
end
