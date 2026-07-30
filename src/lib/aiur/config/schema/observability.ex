defmodule Aiur.Config.Schema.Observability do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:dashboard_enabled, :boolean, default: true)
    # The dashboard is an authenticated operator surface and its controls are
    # live by default. HTTP startup still refuses writable non-loopback binds
    # without configured dashboard credentials.
    field(:dashboard_writable, :boolean, default: true)
    field(:refresh_ms, :integer, default: 1_000)
    field(:render_interval_ms, :integer, default: 16)
    field(:telemetry_retention_max_bytes, :integer, default: 64 * 1024 * 1024)
    field(:telemetry_retention_max_age_days, :integer, default: 30)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :dashboard_enabled,
        :dashboard_writable,
        :refresh_ms,
        :render_interval_ms,
        :telemetry_retention_max_bytes,
        :telemetry_retention_max_age_days
      ], empty_values: [])
    |> validate_number(:refresh_ms, greater_than: 0)
    |> validate_number(:render_interval_ms, greater_than: 0)
    |> validate_number(:telemetry_retention_max_bytes, greater_than: 0)
    |> validate_number(:telemetry_retention_max_age_days, greater_than: 0)
  end
end
