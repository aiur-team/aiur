defmodule Aiur.VoiceConversation.Credentials do
  @moduledoc "Resolves daemon-held voice provider credentials only at use time."
  @behaviour VoiceConverse.Ports.Credentials

  @impl true
  def fetch(provider, purpose) when provider in [:elevenlabs_agents, :elevenlabs] do
    case Aiur.Config.elevenlabs_api_key() do
      key when is_binary(key) ->
        if String.trim(key) == "", do: {:error, :missing}, else: present(key, purpose)

      _ ->
        {:error, :missing}
    end
  end

  def fetch(provider, purpose) when provider in [:openai, :openai_realtime] do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) ->
        if String.trim(key) == "", do: {:error, :missing}, else: present(key, purpose)

      _ ->
        {:error, :missing}
    end
  end

  def fetch(_provider, _purpose), do: {:error, :missing}

  defp present(_key, :probe), do: {:ok, :present}
  defp present(key, purpose) when purpose in [:connect, :delete, :provision, :render], do: {:ok, key}
end
