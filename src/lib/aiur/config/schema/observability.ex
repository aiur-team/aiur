defmodule Aiur.Config.Schema.Observability do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:dashboard_enabled, :boolean, default: true)
    # Tailscale Funnel status checks are opt-in because Funnel may serve an
    # unrelated target on some hosts.
    field(:build_order_funnel_health_check, :boolean, default: false)
    # Dashboard writes are enabled by default for authenticated operators;
    # set observability.dashboard_writable: false to make them read-only.
    field(:dashboard_writable, :boolean, default: true)
    field(:refresh_ms, :integer, default: 1_000)
    field(:render_interval_ms, :integer, default: 16)
    field(:capture_tags, :map, default: %{})
    field(:capture_label_prefixes, {:array, :string}, default: ["experiment:", "cohort:", "feature:"])
    field(:telemetry_enabled, :boolean, default: true)
    field(:telemetry_retention_max_bytes, :integer, default: 64 * 1024 * 1024)
    field(:telemetry_retention_max_age_days, :integer, default: 30)
    field(:telemetry_retention_prune_interval_bytes, :integer)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :dashboard_enabled,
        :build_order_funnel_health_check,
        :dashboard_writable,
        :refresh_ms,
        :render_interval_ms,
        :capture_tags,
        :capture_label_prefixes,
        :telemetry_enabled,
        :telemetry_retention_max_bytes,
        :telemetry_retention_max_age_days,
        :telemetry_retention_prune_interval_bytes
      ],
      empty_values: []
    )
    |> validate_change(:capture_tags, &validate_tags/2)
    |> validate_length(:capture_label_prefixes, max: 20)
    |> validate_number(:refresh_ms, greater_than: 0)
    |> validate_number(:render_interval_ms, greater_than: 0)
    |> validate_number(:telemetry_retention_max_bytes, greater_than: 0)
    |> validate_number(:telemetry_retention_max_age_days, greater_than: 0)
    |> validate_number(:telemetry_retention_prune_interval_bytes, greater_than: 0)
  end

  defp validate_tags(field, tags) do
    if map_size(tags) <= 20 and Enum.all?(tags, fn {key, value} -> is_binary(key) and is_binary(value) and String.length(key) <= 64 and String.length(value) <= 64 end),
      do: [],
      else: [{field, "must contain at most 20 string pairs of at most 64 characters"}]
  end
end
