defmodule Aiur.Config.Schema.BuildQueue do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:enabled, :boolean, default: true)
    field(:start_trigger, :string, default: "pr_merged")
    field(:reconcile_interval_seconds, :integer, default: 60)
    field(:max_writes_per_minute, :integer, default: 20)
    field(:observation_max_age_seconds, :integer, default: nil)
    field(:merged_open_grace_seconds, :integer, default: 600)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:start_trigger, :enabled, :reconcile_interval_seconds, :max_writes_per_minute, :observation_max_age_seconds, :merged_open_grace_seconds], empty_values: [])
    |> validate_inclusion(:start_trigger, Enum.map(Aiur.StartTrigger.triggers(), &Atom.to_string/1), message: "must be one of: #{Enum.join(Aiur.StartTrigger.triggers(), ", ")}")
    |> validate_required([:start_trigger])
    |> validate_number(:reconcile_interval_seconds, greater_than_or_equal_to: 10, less_than_or_equal_to: 3600)
    |> validate_number(:max_writes_per_minute, greater_than_or_equal_to: 1, less_than_or_equal_to: 60)
    |> validate_number(:observation_max_age_seconds, greater_than_or_equal_to: 10, less_than_or_equal_to: 3600)
    |> validate_number(:merged_open_grace_seconds, greater_than_or_equal_to: 60, less_than_or_equal_to: 86_400)
  end
end
