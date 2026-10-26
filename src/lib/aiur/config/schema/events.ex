defmodule Aiur.Config.Schema.Events do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.Schema.EventsExport

  require EventsExport
  @primary_key false
  @type t :: %__MODULE__{}

  embedded_schema do
    embeds_one(:export, EventsExport, on_replace: :update, defaults_to_struct: true)

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
    |> cast_embed(:export, with: &EventsExport.changeset/2)
    |> validate_number(:block_state_debounce_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:custom_events_per_turn_max, greater_than: 0)
    |> validate_number(:codeowners_refresh_seconds, greater_than: 0)
  end
end
