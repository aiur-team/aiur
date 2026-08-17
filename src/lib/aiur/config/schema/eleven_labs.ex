defmodule Aiur.Config.Schema.ElevenLabs do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    # ElevenLabs speech-to-text credential for Stream Deck voice input. A secret:
    # prefer the `$ELEVENLABS_API_KEY` env reference over an inline value, and
    # note the daemon scrubs `*_API_KEY` from every agent environment.
    field(:api_key, :string)
    # ISO-639-3 transcription language handed to the ElevenLabs API ("eng" for
    # English). Leave the default unless dictating in another language.
    field(:language_code, :string, default: "eng")
    # Stock or owned voice used for dashboard conversation replies. Voice IDs
    # are account-visible identifiers, not credentials.
    field(:voice_id, :string)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:api_key, :language_code, :voice_id], empty_values: [])
  end
end
