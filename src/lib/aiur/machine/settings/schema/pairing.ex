defmodule Aiur.Machine.Settings.Schema.Pairing do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Machine.Settings.Validation

  @primary_key false
  embedded_schema do
    field(:secret_ttl_seconds, :integer, default: 600)
    field(:max_devices, :integer, default: 20)
    field(:pin_rotation_grace_seconds, :integer, default: 604_800)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> Validation.cast(attrs)
    |> validate_number(:secret_ttl_seconds, greater_than_or_equal_to: 60, less_than_or_equal_to: 3600)
    |> validate_number(:max_devices, greater_than_or_equal_to: 1, less_than_or_equal_to: 200)
    |> validate_number(:pin_rotation_grace_seconds, greater_than_or_equal_to: 3600)
  end
end
