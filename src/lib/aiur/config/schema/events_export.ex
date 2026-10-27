defmodule Aiur.Config.Schema.EventsExport do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-11 events.export.enabled
    # @config-detail events.export.enabled | boolean | false | Enables the external event journal; restart to apply. Reserved for the exporter; no feed is installed yet. |
    field(:enabled, :boolean, default: false)
    # @config-reference config-configuration-11 events.export.retention_days
    # @config-detail events.export.retention_days | integer | 7 | Retention age in days (1..90); older records are trimmed. Read at boot. |
    field(:retention_days, :integer, default: 7)
    # @config-reference config-configuration-11 events.export.retention_max_events
    # @config-detail events.export.retention_max_events | integer | 50000 | Maximum retained records (1000..1000000); the first retention bound reached applies. Read at boot. |
    field(:retention_max_events, :integer, default: 50_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :retention_days, :retention_max_events], empty_values: [])
    |> validate_required([:enabled, :retention_days, :retention_max_events])
    |> validate_number(:retention_days, greater_than_or_equal_to: 1, less_than_or_equal_to: 90)
    |> validate_number(:retention_max_events, greater_than_or_equal_to: 1_000, less_than_or_equal_to: 1_000_000)
  end
end
