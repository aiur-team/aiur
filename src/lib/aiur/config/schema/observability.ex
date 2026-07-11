defmodule Aiur.Config.Schema.Observability do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:dashboard_enabled, :boolean, default: true)
    # Read-only by default: the dashboard's agent-write paths (operator chat,
    # pause) are disabled until a deliberate dashboard parity pass. Flip to
    # `true` to re-enable them. See issue #371.
    field(:dashboard_writable, :boolean, default: false)
    field(:refresh_ms, :integer, default: 1_000)
    field(:render_interval_ms, :integer, default: 16)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:dashboard_enabled, :dashboard_writable, :refresh_ms, :render_interval_ms], empty_values: [])
    |> validate_number(:refresh_ms, greater_than: 0)
    |> validate_number(:render_interval_ms, greater_than: 0)
  end
end
