defmodule Aiur.Config.Schema.Experiments do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:enabled, :boolean, default: true)
    field(:default_min_samples, :integer, default: 15)
    field(:default_before_days, :integer, default: 14)
    field(:pack_dirs, {:array, :string}, default: [".aiur/experiments/packs"])
    field(:disabled_packs, {:array, :string}, default: [])
    field(:script_timeout_ms, :integer, default: 60_000)
    field(:checkpoint_interval_ms, :integer, default: 3_600_000)
    field(:max_snapshot_observations, :integer, default: 50_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    fields = __MODULE__.__schema__(:fields)
    numbers = [:default_min_samples, :default_before_days, :script_timeout_ms, :checkpoint_interval_ms, :max_snapshot_observations]

    schema
    |> cast(attrs, fields, empty_values: [])
    |> validate_required([:enabled | numbers])
    |> then(fn changeset -> Enum.reduce(numbers, changeset, &validate_number(&2, &1, greater_than: 0)) end)
  end
end
