defmodule Aiur.Machine.Settings.Schema do
  @moduledoc "Embedded machine settings tree, independent of workflow configuration."
  use Ecto.Schema
  alias Aiur.Machine.Settings.Schema.{Gateway, Mobile, Pairing, Transport}
  alias Aiur.Machine.Settings.Validation

  @primary_key false
  embedded_schema do
    embeds_one(:mobile, Mobile, defaults_to_struct: true, on_replace: :update)
    embeds_one(:gateway, Gateway, defaults_to_struct: true, on_replace: :update)
    embeds_one(:pairing, Pairing, defaults_to_struct: true, on_replace: :update)
    embeds_one(:transport, Transport, defaults_to_struct: true, on_replace: :update)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs), do: Validation.cast(schema, attrs)
end
