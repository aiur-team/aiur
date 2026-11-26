defmodule Aiur.Machine.Settings.Schema.Mobile do
  @moduledoc false
  use Ecto.Schema
  alias Aiur.Machine.Settings.Validation

  @primary_key false
  embedded_schema do
    field(:enabled, :boolean, default: false)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs), do: Validation.cast(schema, attrs)
end
