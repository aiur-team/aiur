defmodule Aiur.Config.Schema.Experiments do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Config.Schema.Experiments.Auto
  require Auto

  @primary_key false
  embedded_schema do
    embeds_one(:auto, Auto, on_replace: :update, defaults_to_struct: true)
    # @config-reference config-configuration-20 experiments.enabled
    # @config-detail experiments.enabled | boolean | true | Start the experiment store. Disabled stores refuse writes. |
    field(:enabled, :boolean, default: true)
    # @config-reference config-configuration-20 experiments.default_min_samples
    # @config-detail experiments.default_min_samples | integer | 15 | Minimum samples per arm; positive. |
    field(:default_min_samples, :integer, default: 15)
    # @config-reference config-configuration-20 experiments.default_before_days
    # @config-detail experiments.default_before_days | integer | 14 | Default baseline window in days; positive. |
    field(:default_before_days, :integer, default: 14)
    # @config-reference config-configuration-20 experiments.pack_dirs
    # @config-detail experiments.pack_dirs | string list | [".aiur/experiments/packs"] | Consumer metric pack directories, relative to the base checkout; reserved for metric packs. |
    field(:pack_dirs, {:array, :string}, default: [".aiur/experiments/packs"])
    # @config-reference config-configuration-20 experiments.disabled_packs
    # @config-detail experiments.disabled_packs | string list | [] | Pack IDs to disable; reserved for metric packs. |
    field(:disabled_packs, {:array, :string}, default: [])
    # @config-reference config-configuration-20 experiments.script_timeout_ms
    # @config-detail experiments.script_timeout_ms | integer | 60000 | Script metric timeout in milliseconds; positive, reserved for metric packs. |
    field(:script_timeout_ms, :integer, default: 60_000)
    # @config-reference config-configuration-20 experiments.checkpoint_interval_ms
    # @config-detail experiments.checkpoint_interval_ms | integer | 3600000 | Observation checkpoint interval in milliseconds; positive, reserved for snapshot capture. |
    field(:checkpoint_interval_ms, :integer, default: 3_600_000)
    # @config-reference config-configuration-20 experiments.max_snapshot_observations
    # @config-detail experiments.max_snapshot_observations | integer | 50000 | Maximum observations in a snapshot; positive, reserved for snapshot capture. |
    field(:max_snapshot_observations, :integer, default: 50_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    fields = __MODULE__.__schema__(:fields)
    numbers = [:default_min_samples, :default_before_days, :script_timeout_ms, :checkpoint_interval_ms, :max_snapshot_observations]

    schema
    |> cast(attrs, fields -- [:auto], empty_values: [])
    |> cast_embed(:auto, with: &Auto.changeset/2)
    |> validate_required([:enabled | numbers])
    |> then(fn changeset -> Enum.reduce(numbers, changeset, &validate_number(&2, &1, greater_than: 0)) end)
  end
end
