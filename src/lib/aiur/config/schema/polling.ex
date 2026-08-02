defmodule Aiur.Config.Schema.Polling do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @min_usage_interval_seconds 120

  @primary_key false
  embedded_schema do
    field(:interval_seconds, :integer, default: 30)
    # Usage endpoint allows ~1 request/2min, per account. Measured floor 120s.
    field(:usage_interval_seconds, :integer, default: 300)
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
    # Below the floor the meters degrade silently, so fail loudly instead.
    |> validate_number(:usage_interval_seconds,
      greater_than_or_equal_to: @min_usage_interval_seconds,
      message: "must be at least #{@min_usage_interval_seconds} seconds; the provider usage endpoint allows about one request every two minutes and rejects the rest"
    )
  end
end
