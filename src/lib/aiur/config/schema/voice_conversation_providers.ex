defmodule Aiur.Config.Schema.VoiceConversationProviders do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Config.Schema.{VoiceConversationCascade, VoiceConversationGemini, VoiceConversationOpenAI}

  for source <- ["voice_conversation_cascade.ex", "voice_conversation_gemini.ex", "voice_conversation_openai.ex"],
      do: @external_resource(Path.relative_to(Path.join(__DIR__, source), File.cwd!(), force: true))

  require VoiceConversationCascade
  require VoiceConversationGemini
  require VoiceConversationOpenAI

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-voice-00 voice.conversation.providers.preference
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail voice.conversation.providers.preference | list of strings | [elevenlabs_agents, openai_live, gemini_live, cascade] | Ordered core registry option ids. Unknown ids fail config loading; unavailable adapters are skipped. |
    field(:preference, {:array, Ecto.Enum}, values: VoiceConverse.Providers.Registry.entries() |> Enum.map(&elem(&1, 0)), default: VoiceConverse.Providers.default_preference())
    # @config-reference config-configuration-voice-00 voice.conversation.providers.mode
    # @config-detail voice.conversation.providers.mode | string | voice | Requested conversation mode: `voice` or `text`. |
    field(:mode, Ecto.Enum, values: [:voice, :text], default: :voice)
    # @config-reference config-configuration-voice-00 voice.conversation.providers.on_missing_credential
    # @config-detail voice.conversation.providers.on_missing_credential | string | text_only | Missing-key policy: `next`, `text_only` or `refuse`. Text fallback must be listed in preference. |
    field(:on_missing_credential, Ecto.Enum, values: [:next, :text_only, :refuse], default: VoiceConverse.ProviderConfig.default().on_missing_credential)
    embeds_one(:openai, VoiceConversationOpenAI, on_replace: :update, defaults_to_struct: true)
    embeds_one(:gemini, VoiceConversationGemini, on_replace: :update, defaults_to_struct: true)
    embeds_one(:cascade, VoiceConversationCascade, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:preference, :mode, :on_missing_credential], empty_values: [])
    |> validate_length(:preference, min: 1)
    |> validate_change(:preference, fn :preference, choices ->
      if Enum.any?(choices, &is_nil/1), do: [preference: "must not contain empty entries"], else: []
    end)
    |> cast_embed(:openai)
    |> cast_embed(:gemini)
    |> cast_embed(:cascade)
    |> validate_required([:preference, :mode, :on_missing_credential, :openai, :gemini, :cascade])
  end

  @spec to_core(struct()) :: map()
  def to_core(schema) do
    schema
    |> Map.take([:preference, :mode, :on_missing_credential])
    |> Map.put(:openai, Map.from_struct(schema.openai))
    |> Map.put(:gemini, Map.from_struct(schema.gemini))
    |> Map.put(:cascade, VoiceConversationCascade.to_core(schema.cascade))
  end
end
