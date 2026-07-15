defmodule Aiur.Config.Schema.BuildOrder do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:ticket_detail_freshness_ms, :integer, default: 30_000)
    field(:ticket_detail_max_entries, :integer, default: 32)
    field(:ticket_detail_max_description_bytes, :integer, default: 16_384)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [:ticket_detail_freshness_ms, :ticket_detail_max_entries, :ticket_detail_max_description_bytes],
      empty_values: []
    )
    |> validate_number(:ticket_detail_freshness_ms, greater_than: 0, less_than_or_equal_to: 300_000)
    |> validate_number(:ticket_detail_max_entries, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:ticket_detail_max_description_bytes, greater_than: 0, less_than_or_equal_to: 16_384)
  end
end
