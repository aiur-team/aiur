defmodule Aiur.VoiceConverse.Host.Credentials do
  @moduledoc "Resolves daemon-held voice provider credentials only at use time."
  @behaviour VoiceConverse.Ports.Credentials

  @env_names %{openai: "OPENAI_API_KEY", gemini: "GEMINI_API_KEY", anthropic: "ANTHROPIC_API_KEY"}

  @spec names() :: map()
  def names, do: Map.put(@env_names, :elevenlabs, "elevenlabs.api_key / ELEVENLABS_API_KEY")

  @impl true
  def fetch(provider, purpose) when provider in [:elevenlabs_agents, :elevenlabs] do
    case Aiur.Config.elevenlabs_api_key() do
      key when is_binary(key) ->
        if String.trim(key) == "", do: {:error, :missing}, else: present(key, purpose)

      _ ->
        {:error, :missing}
    end
  end

  def fetch(:openai_realtime, purpose), do: fetch(:openai, purpose)
  def fetch(provider, purpose), do: fetch(provider, purpose, [])

  @doc false
  @spec fetch(atom(), atom(), keyword()) :: {:ok, :present | String.t()} | {:error, :missing}
  def fetch(provider, purpose, opts) do
    with variable when is_binary(variable) <- Map.get(Keyword.get(opts, :env_names, @env_names), provider),
         key when is_binary(key) <- System.get_env(variable),
         true <- String.trim(key) != "" do
      present(key, purpose)
    else
      _ -> {:error, :missing}
    end
  end

  defp present(_key, :probe), do: {:ok, :present}
  defp present(key, purpose) when purpose in [:connect, :delete, :provision, :render], do: {:ok, key}
end
