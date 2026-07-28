defmodule Aiur.Config.Schema.Polling do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:interval_seconds, :integer, default: 30)
    # How often provider usage/limits are re-observed while agents are running.
    # Separate from the GitHub poll above: observing usage costs a provider
    # session, so it is deliberately coarser and independently tunable.
    field(:usage_interval_seconds, :integer, default: 60)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    if Map.has_key?(attrs, "interval_ms") or Map.has_key?(attrs, :interval_ms) do
      raise ArgumentError,
            "polling.interval_ms is no longer supported; rename to interval_seconds " <>
              "(value in seconds, not milliseconds)"
    end

    schema
    |> cast(attrs, [:interval_seconds, :usage_interval_seconds], empty_values: [])
    |> validate_number(:interval_seconds, greater_than: 0)
    |> validate_number(:usage_interval_seconds, greater_than: 0)
  end
end
