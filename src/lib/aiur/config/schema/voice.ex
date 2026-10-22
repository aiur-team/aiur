defmodule Aiur.Config.Schema.Voice do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  # Root of the `voice:` section. Its subsections are added by the voice
  # component's own schema modules.
  @primary_key false
  embedded_schema do
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs), do: cast(schema, attrs, [])
end
