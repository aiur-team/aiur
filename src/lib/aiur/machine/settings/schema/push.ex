defmodule Aiur.Machine.Settings.Schema.Push do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Machine.Settings.Schema.Push.Outbox
  alias Aiur.Machine.Settings.Validation

  @primary_key false
  embedded_schema do
    field(:enabled, :boolean, default: false)
    field(:send_timeout_ms, :integer, default: 5_000)
    embeds_one(:outbox, Outbox, defaults_to_struct: true, on_replace: :update)
    field(:allow_loopback_relay, :boolean, default: false)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> Validation.cast(attrs)
    |> validate_number(:send_timeout_ms, greater_than_or_equal_to: 500, less_than_or_equal_to: 30_000)
  end
end
