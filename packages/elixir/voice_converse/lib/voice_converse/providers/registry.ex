defmodule VoiceConverse.Providers.Registry do
  @moduledoc false

  @credential_env %{
    anthropic: "ANTHROPIC_API_KEY",
    elevenlabs: "ELEVENLABS_API_KEY",
    gemini: "GEMINI_API_KEY",
    openai: "OPENAI_API_KEY"
  }
  @part_credentials %{
    elevenlabs_stt: :elevenlabs,
    elevenlabs_tts: :elevenlabs,
    openai_stt: :openai,
    openai_tts: :openai
  }
  @registry [
    {:openai_live, VoiceConverse.Providers.OpenAILive,
     %{
       id: :openai_live,
       family: :speech_to_speech,
       label: "OpenAI Live",
       modes: [:voice],
       needs: [:openai],
       privacy: %{audio_stored_by_provider: true, deletable?: false},
       price_hint: "about USD 0.05/min"
     }},
    {:openai_realtime, VoiceConverse.Providers.OpenAIRealtime,
     %{
       id: :openai_realtime,
       family: :speech_to_speech,
       label: "OpenAI Realtime",
       modes: [:voice],
       needs: [:openai],
       privacy: %{audio_stored_by_provider: true, deletable?: false},
       price_hint: "token-priced"
     }},
    {:gemini_live, VoiceConverse.Providers.GeminiLive,
     %{
       id: :gemini_live,
       family: :speech_to_speech,
       label: "Gemini Live",
       modes: [:voice],
       needs: [:gemini],
       privacy: %{audio_stored_by_provider: true, deletable?: false},
       price_hint: "about USD 0.023/min"
     }},
    {:elevenlabs_agents, VoiceConverse.Providers.ElevenLabsAgents,
     %{
       id: :elevenlabs_agents,
       family: :hosted_agent,
       label: "ElevenLabs Agents",
       modes: [:voice, :text],
       needs: [:elevenlabs],
       privacy: %{audio_stored_by_provider: true, deletable?: true},
       price_hint: "about USD 0.08/min"
     }},
    {:cascade, nil,
     %{
       id: :cascade,
       family: :cascade,
       label: "Cascade",
       modes: [:voice, :text],
       needs: [],
       privacy: %{audio_stored_by_provider: false, deletable?: false},
       price_hint: "depends on selected parts"
     }},
    {:text_only, nil,
     %{
       id: :text_only,
       family: :cascade,
       label: "Text only",
       modes: [:text],
       needs: [],
       privacy: %{audio_stored_by_provider: false, deletable?: false},
       price_hint: "model-token-priced"
     }},
    {:codex_realtime, VoiceConverse.Providers.CodexRealtime,
     %{
       id: :codex_realtime,
       family: :agent_native,
       label: "Codex Realtime",
       modes: [:voice, :text],
       needs: [:openai],
       privacy: %{audio_stored_by_provider: false, deletable?: false},
       price_hint: "experimental"
     }}
  ]

  @spec entries() :: [{atom(), module() | nil, map()}]
  def entries, do: @registry

  @spec entry(atom()) :: {atom(), module() | nil, map()} | nil
  def entry(id), do: Enum.find(@registry, fn {option_id, _module, _fallback} -> option_id == id end)

  @spec credential_env(atom()) :: String.t() | nil
  def credential_env(provider), do: Map.get(@credential_env, provider)

  @spec credential_for_part(atom()) :: atom() | nil
  def credential_for_part(part), do: Map.get(@part_credentials, part)

  @spec descriptor(atom(), module() | nil, map()) :: map()
  def descriptor(_id, nil, fallback), do: fallback

  def descriptor(_id, module, fallback) do
    if Code.ensure_loaded?(module) and function_exported?(module, :descriptor, 0) do
      module.descriptor()
      |> Map.drop([:id, :family, :needs])
      |> then(&Map.merge(fallback, &1))
    else
      fallback
    end
  end

  @spec adapter_available?(module() | nil) :: boolean()
  def adapter_available?(nil), do: true

  def adapter_available?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :descriptor, 0)
end
