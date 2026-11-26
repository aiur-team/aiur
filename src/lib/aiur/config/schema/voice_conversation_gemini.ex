defmodule Aiur.Config.Schema.VoiceConversationGemini do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-voice-00 voice.conversation.providers.gemini.live_model
    # @config-detail voice.conversation.providers.gemini.live_model | string or nil | nil | Gemini Live model; nil uses the adapter default. |
    field(:live_model, :string)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs), do: cast(schema, attrs, [:live_model])
end
