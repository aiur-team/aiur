defmodule Aiur.Config.Schema.VoiceConversationCascade do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @defaults VoiceConverse.ProviderConfig.default().cascade
  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-voice-00 voice.conversation.providers.cascade.stt
    # @config-detail voice.conversation.providers.cascade.stt | list of strings | [browser_stt] | Ordered speech recognition parts, validated by the core. |
    field(:stt, {:array, :string}, default: Enum.map(@defaults.stt, &to_string/1))
    # @config-reference config-configuration-voice-00 voice.conversation.providers.cascade.llm
    # @config-detail voice.conversation.providers.cascade.llm | string or nil | nil | Cascade/text-only model as `anthropic:model`, `openai:model` or `gemini:model`. |
    field(:llm, :string)
    # @config-reference config-configuration-voice-00 voice.conversation.providers.cascade.tts
    # @config-detail voice.conversation.providers.cascade.tts | list of strings | [browser_tts] | Ordered speech synthesis parts, validated by the core. |
    field(:tts, {:array, :string}, default: Enum.map(@defaults.tts, &to_string/1))
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:stt, :llm, :tts], empty_values: [])
    |> validate_required([:stt, :tts])
    |> validate_core()
  end

  @spec to_core(struct()) :: map()
  def to_core(schema) do
    # The core's part atoms may not exist yet in a freshly booted VM.
    Code.ensure_loaded!(VoiceConverse.ProviderConfig)
    %{stt: parts(schema.stt), llm: schema.llm, tts: parts(schema.tts)}
  end

  defp parts(nil), do: nil
  defp parts(values), do: Enum.map(values, &existing_atom/1)

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :unknown_part
  end

  defp validate_core(%{valid?: false} = changeset), do: changeset

  defp validate_core(changeset) do
    providers = VoiceConverse.ProviderConfig.merge(%{cascade: to_core(apply_changes(changeset))})

    case VoiceConverse.ProviderConfig.validate(providers) do
      :ok -> changeset
      {:error, %{key: key}} -> add_error(changeset, key, "is invalid")
    end
  end
end
