defmodule Aiur.Config.Schema.VoiceConversationOpenAI do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-voice-00 voice.conversation.providers.openai.live_model
    # @config-detail voice.conversation.providers.openai.live_model | string or nil | nil | OpenAI Live model; nil uses the adapter default. |
    field(:live_model, :string)
    # @config-reference config-configuration-voice-00 voice.conversation.providers.openai.realtime_model
    # @config-detail voice.conversation.providers.openai.realtime_model | string or nil | nil | OpenAI Realtime model; nil uses the adapter default. |
    field(:realtime_model, :string)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs), do: cast(schema, attrs, [:live_model, :realtime_model])
end
