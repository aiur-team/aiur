defmodule Aiur.Machine.Settings.Schema.Capacity do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Machine.Settings.Validation

  @primary_key false
  embedded_schema do
    field(:max_agents, :integer)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> Validation.cast(attrs, nullable: true)
    |> validate_number(:max_agents, greater_than_or_equal_to: 1)
  end
end
