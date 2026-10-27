defmodule Aiur.Config.Schema.Experiments.Auto do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-20 experiments.auto.enabled
    # @config-detail experiments.auto.enabled | boolean | true | Enable automatic line workers and the deploy ledger. |
    field(:enabled, :boolean, default: true)
    # @config-reference config-configuration-20 experiments.auto.version_line
    # @config-detail experiments.auto.version_line | boolean | true | Enable base-semver version lines. |
    field(:version_line, :boolean, default: true)
    # @config-reference config-configuration-20 experiments.auto.release_line
    # @config-detail experiments.auto.release_line | boolean | true | Enable repository release lines. |
    field(:release_line, :boolean, default: true)
    # @config-reference config-configuration-20 experiments.auto.release_tag_pattern
    # @config-detail experiments.auto.release_tag_pattern | string | v* | Release tag pattern; non-empty, no whitespace. |
    field(:release_tag_pattern, :string, default: "v*")
    # @config-reference config-configuration-20 experiments.auto.release_include_prereleases
    # @config-detail experiments.auto.release_include_prereleases | boolean | false | Include prerelease tags. |
    field(:release_include_prereleases, :boolean, default: false)
    # @config-reference config-configuration-20 experiments.auto.release_min_interval_days
    # @config-detail experiments.auto.release_min_interval_days | integer | 7 | Minimum days between release lines; positive. |
    field(:release_min_interval_days, :integer, default: 7)
    # @config-reference config-configuration-20 experiments.auto.feature_label
    # @config-detail experiments.auto.feature_label | string | experiment:feature | Non-empty label marking measured feature epics. |
    field(:feature_label, :string, default: "experiment:feature")
    # @config-reference config-configuration-20 experiments.auto.feature_live_signal
    # @config-detail experiments.auto.feature_live_signal | string | auto | One of auto, merge, release, daemon_boot. |
    field(:feature_live_signal, :string, default: "auto")
    # @config-reference config-configuration-20 experiments.auto.feature_quiet_hours
    # @config-detail experiments.auto.feature_quiet_hours | integer | 6 | Hours without new epic members; positive. |
    field(:feature_quiet_hours, :integer, default: 6)
    # @config-reference config-configuration-20 experiments.auto.live_signal_max_wait_hours
    # @config-detail experiments.auto.live_signal_max_wait_hours | integer | 72 | Hours before falling back to merge time; positive. |
    field(:live_signal_max_wait_hours, :integer, default: 72)
    # @config-reference config-configuration-20 experiments.auto.before_days
    # @config-detail experiments.auto.before_days | integer | 14 | Baseline window length in days; positive. |
    field(:before_days, :integer, default: 14)
    # @config-reference config-configuration-20 experiments.auto.after_days
    # @config-detail experiments.auto.after_days | integer | 14 | Initial after window length in days; positive. |
    field(:after_days, :integer, default: 14)
    # @config-reference config-configuration-20 experiments.auto.after_step_days
    # @config-detail experiments.auto.after_step_days | integer | 7 | After window extension in days; positive. |
    field(:after_step_days, :integer, default: 7)
    # @config-reference config-configuration-20 experiments.auto.after_max_days
    # @config-detail experiments.auto.after_max_days | integer | 42 | Maximum after window days; at least after_days. |
    field(:after_max_days, :integer, default: 42)
    # @config-reference config-configuration-20 experiments.auto.metric_packs
    # @config-detail experiments.auto.metric_packs | string list | ["delivery"] | Metric packs used for automatic experiments. |
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
