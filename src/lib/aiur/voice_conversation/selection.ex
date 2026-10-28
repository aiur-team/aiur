defmodule Aiur.VoiceConversation.Selection do
  @moduledoc "Validates dashboard provider/model choices without changing daemon configuration."

  alias Aiur.VoiceConversation
  alias Aiur.VoiceConversation.{Comparison, Credentials}

  @spec options(map()) :: {:ok, keyword()} | {:error, term()}
  def options(payload) do
    settings = Aiur.Config.voice_conversation()

    with {:ok, config} <- VoiceConversation.config(), do: build_options(payload, settings, config, &Credentials.fetch/2)
  end

  @doc false
  @spec build_options(map(), map(), VoiceConverse.Config.t(), function()) :: {:ok, keyword()} | {:error, term()}
  def build_options(payload, settings, config, probe) do
    choice = Map.get(payload, "provider", to_string(settings.provider))
    model = Map.get(payload, "model", settings.llm)

    with true <- choice in ["elevenlabs_agents", "openai_realtime"],
         true <- is_binary(model) and byte_size(model) in 1..120 and String.trim(model) != "",
         {:ok, provider} <- provider(choice, settings),
         {:ok, :present} <- probe.(provider_id(choice), :probe),
         :ok <- VoiceConverse.Config.check_session_start(%{config | llm: model}) do
      {:ok, [provider: provider, llm: model, comparison: %{root: config.transcript_root, provider: choice, model: model, max_seconds: config.limits.max_session_seconds}]}
    else
      _ -> {:error, :unconfigured}
    end
  end

  @spec snapshot() :: {:ok, map()} | {:error, term()}
  def snapshot do
    with {:ok, config} <- VoiceConversation.config(), do: Comparison.snapshot(config.transcript_root)
  end

  @spec rate(String.t(), integer(), String.t()) :: :ok | {:error, term()}
  def rate(id, rating, note) do
    with {:ok, config} <- VoiceConversation.config(), do: Comparison.rate(config.transcript_root, id, rating, note)
  end

  defp provider("openai_realtime", settings), do: {:ok, {VoiceConversation.OpenAIProvider, [voice_id: settings.voice_id]}}
  defp provider("elevenlabs_agents", %{agent_id: id}) when is_binary(id), do: {:ok, {VoiceConversation.Provider, [agent_id: id]}}
  defp provider(_choice, _settings), do: {:error, :unconfigured}
  defp provider_id("openai_realtime"), do: :openai_realtime
  defp provider_id("elevenlabs_agents"), do: :elevenlabs_agents
end
