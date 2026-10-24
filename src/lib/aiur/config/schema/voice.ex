defmodule Aiur.Config.Schema.Voice do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.Schema.VoiceConversation

  # Embedded struct defaults must rebuild when the nested schema changes.
  require VoiceConversation

  @type t :: %__MODULE__{}

  # Root of the `voice:` section.
  @primary_key false
  embedded_schema do
    embeds_one(:conversation, VoiceConversation, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [])
    |> cast_embed(:conversation, with: &VoiceConversation.changeset/2)
  end
end
