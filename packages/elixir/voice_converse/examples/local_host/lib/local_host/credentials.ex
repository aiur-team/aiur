defmodule LocalHost.Credentials do
  @moduledoc "Environment credentials read only at the port boundary."
  @behaviour VoiceConverse.Ports.Credentials
  @names %{
    openai: "OPENAI_API_KEY",
    openai_realtime: "OPENAI_API_KEY",
    gemini: "GEMINI_API_KEY",
    anthropic: "ANTHROPIC_API_KEY",
    elevenlabs: "ELEVENLABS_API_KEY",
    elevenlabs_agents: "ELEVENLABS_API_KEY"
  }
  @impl true
  def fetch(provider, purpose) do
    case @names[provider] && System.get_env(@names[provider]) do
      value when is_binary(value) and value != "" ->
        if purpose == :probe, do: {:ok, :present}, else: {:ok, value}

      _ ->
        {:error, :missing}
    end
  end
end
