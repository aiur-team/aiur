defmodule Aiur.Config.Schema.Events do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-11 events.block_state_debounce_seconds
    # @config-detail events.block_state_debounce_seconds | integer | 10 | Debounces blocked/unblocked transitions. |
    field(:block_state_debounce_seconds, :integer, default: 10)
    # @config-reference config-configuration-11 events.custom_events_per_turn_max
    # @config-detail events.custom_events_per_turn_max | integer | 5 | Caps custom events per turn. |
    field(:custom_events_per_turn_max, :integer, default: 5)
    # @config-reference config-configuration-11 events.codeowners_refresh_seconds
    # @config-detail events.codeowners_refresh_seconds | integer | 3600 | CODEOWNERS refresh interval. |
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
