defmodule Aiur.Config.Schema.Monitoring do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:daemon_heartbeat_stale_ms, :integer, default: 3_600_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:daemon_heartbeat_stale_ms], empty_values: [])
    |> validate_number(:daemon_heartbeat_stale_ms, greater_than: 0)
  end
end
