defmodule Aiur.Config.Schema.BuildQueue do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:set_order, :string, default: "none")
    field(:max_active_sets, :integer, default: nil)
    field(:spill_reserve_slots, :integer, default: 0)
    field(:enabled, :boolean, default: true)
    field(:start_trigger, :string, default: "pr_merged")
    field(:optimistic_slot_share, :float, default: 0.5)
    field(:reconcile_interval_seconds, :integer, default: 60)
    field(:max_writes_per_minute, :integer, default: 20)
    field(:observation_max_age_seconds, :integer, default: nil)
    field(:merged_open_grace_seconds, :integer, default: 600)
    field(:optimistic_failure_grace_seconds, :integer, default: 600)
    field(:optimistic_churn_attention_threshold, :integer, default: 3)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :set_order,
        :max_active_sets,
        :spill_reserve_slots,
        :optimistic_slot_share,
        :start_trigger,
        :enabled,
        :reconcile_interval_seconds,
        :max_writes_per_minute,
        :observation_max_age_seconds,
        :merged_open_grace_seconds,
        :optimistic_failure_grace_seconds,
        :optimistic_churn_attention_threshold
      ],
      empty_values: []
    )
    |> validate_inclusion(:start_trigger, Enum.map(Aiur.StartTrigger.triggers(), &Atom.to_string/1), message: "must be one of: #{Enum.join(Aiur.StartTrigger.triggers(), ", ")}")
    |> validate_required([:start_trigger, :optimistic_slot_share, :set_order, :spill_reserve_slots])
    |> validate_inclusion(:set_order, ["ranked", "none"])
    |> validate_number(:max_active_sets, greater_than_or_equal_to: 1)
    |> validate_number(:spill_reserve_slots, greater_than_or_equal_to: 0)
    |> validate_number(:optimistic_slot_share, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:reconcile_interval_seconds, greater_than_or_equal_to: 10, less_than_or_equal_to: 3600)
    |> validate_number(:max_writes_per_minute, greater_than_or_equal_to: 1, less_than_or_equal_to: 60)
    |> validate_number(:observation_max_age_seconds, greater_than_or_equal_to: 10, less_than_or_equal_to: 3600)
    |> validate_number(:optimistic_failure_grace_seconds, greater_than_or_equal_to: 60, less_than_or_equal_to: 86_400)
    |> validate_number(:optimistic_churn_attention_threshold, greater_than_or_equal_to: 0, less_than_or_equal_to: 50)
    |> validate_number(:merged_open_grace_seconds, greater_than_or_equal_to: 60, less_than_or_equal_to: 86_400)
  end
end
