defmodule Aiur.Config.Schema.Events do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:block_state_debounce_seconds, :integer, default: 10)
    field(:custom_events_per_turn_max, :integer, default: 5)
    field(:codeowners_refresh_seconds, :integer, default: 3_600)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [:block_state_debounce_seconds, :custom_events_per_turn_max, :codeowners_refresh_seconds],
      empty_values: []
    )
    |> validate_number(:block_state_debounce_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:custom_events_per_turn_max, greater_than: 0)
    |> validate_number(:codeowners_refresh_seconds, greater_than: 0)
  end
end
