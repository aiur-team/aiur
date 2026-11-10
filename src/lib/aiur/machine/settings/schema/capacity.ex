defmodule Aiur.Machine.Settings.Schema.Capacity do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Config.CapacityPolicy
  alias Aiur.Machine.Settings.Validation

  @primary_key false
  embedded_schema do
    field(:max_agents, :integer)
    # Keyed by backend; shape checked by Aiur.Config.CapacityPolicy.
    field(:sources, :map, default: %{})
    field(:limits, :map, default: %{})
    field(:default_burn_percent_per_hour, :float)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> Validation.cast(attrs, nullable: true)
    |> validate_number(:max_agents, greater_than_or_equal_to: 1)
    |> validate_number(:default_burn_percent_per_hour, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_change(:sources, &CapacityPolicy.source_errors(&1, &2, :machine))
    |> validate_change(:limits, &CapacityPolicy.limit_errors/2)
  end
end
