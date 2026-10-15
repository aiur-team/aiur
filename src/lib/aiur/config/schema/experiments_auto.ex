defmodule Aiur.Config.Schema.Experiments.Auto do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:enabled, :boolean, default: true)
    field(:version_line, :boolean, default: true)
    field(:release_line, :boolean, default: true)
    field(:release_tag_pattern, :string, default: "v*")
    field(:release_include_prereleases, :boolean, default: false)
    field(:release_min_interval_days, :integer, default: 7)
    field(:feature_label, :string, default: "experiment:feature")
    field(:feature_live_signal, :string, default: "auto")
    field(:feature_quiet_hours, :integer, default: 6)
    field(:live_signal_max_wait_hours, :integer, default: 72)
    field(:before_days, :integer, default: 14)
    field(:after_days, :integer, default: 14)
    field(:after_step_days, :integer, default: 7)
    field(:after_max_days, :integer, default: 42)
    field(:metric_packs, {:array, :string}, default: ["delivery"])
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    numbers = [:release_min_interval_days, :feature_quiet_hours, :live_signal_max_wait_hours, :before_days, :after_days, :after_step_days, :after_max_days]

    schema
    |> cast(attrs, __MODULE__.__schema__(:fields), empty_values: [])
    |> validate_required(__MODULE__.__schema__(:fields))
    |> validate_inclusion(:feature_live_signal, ~w(auto merge release daemon_boot))
    |> validate_format(:feature_label, ~r/\S/)
    |> validate_format(:release_tag_pattern, ~r/\A\S+\z/)
    |> then(fn changeset -> Enum.reduce(numbers, changeset, &validate_number(&2, &1, greater_than: 0)) end)
    |> then(fn changeset -> validate_number(changeset, :after_max_days, greater_than_or_equal_to: get_field(changeset, :after_days) || schema.after_days) end)
  end
end
