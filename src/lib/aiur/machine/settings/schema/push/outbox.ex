defmodule Aiur.Machine.Settings.Schema.Push.Outbox do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Machine.Settings.Validation

  @primary_key false
  embedded_schema do
    field(:max_age_seconds, :integer, default: 86_400)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> Validation.cast(attrs)
    |> validate_number(:max_age_seconds, greater_than_or_equal_to: 600, less_than_or_equal_to: 604_800)
  end
end
