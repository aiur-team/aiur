defmodule Aiur.Config.Schema.ElevenLabs do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    # Explicitly false records an init decline and suppresses both configured
    # and ambient credentials. Default true preserves legacy configs.
    # @config-reference config-configuration-14 elevenlabs.enabled
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail elevenlabs.enabled | boolean | true | Enables ElevenLabs voice features. Set false to keep an explicit declined setup choice and suppress configured or environment-provided credentials. Existing configs without this key remain enabled. |
    field(:enabled, :boolean, default: true)
    # ElevenLabs speech-to-text credential for Stream Deck voice input. A secret:
    # prefer the `$ELEVENLABS_API_KEY` env reference over an inline value, and
    # note the daemon scrubs `*_API_KEY` from every agent environment.
    # @config-reference config-configuration-14 elevenlabs.api_key
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail elevenlabs.api_key | string or nil | nil | ElevenLabs credential. Accepts a literal value or a `$ELEVENLABS_API_KEY` environment reference. Speech input needs Speech to Text permission; spoken replies also need Text to Speech permission. |
    field(:api_key, :string)
    # ISO-639-3 transcription language handed to the ElevenLabs API ("eng" for
    # English). Leave the default unless dictating in another language.
    # @config-reference config-configuration-14 elevenlabs.language_code
    # @config-detail elevenlabs.language_code | string | `eng` | ISO-639-3 transcription language. ElevenLabs uses `eng` for English. |
    field(:language_code, :string, default: "eng")
    # Stock or owned voice used for dashboard conversation replies. Voice IDs
    # are account-visible identifiers, not credentials.
    # @config-reference config-configuration-14 elevenlabs.voice_id
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail elevenlabs.voice_id | string or nil | nil | Stock or owned ElevenLabs voice used for Dashboard interactive conversation replies. Find the identifier in **My Voices**; Aiur does not clone or manage voices. |
    field(:voice_id, :string)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:enabled, :api_key, :language_code, :voice_id], empty_values: [])
  end
end
