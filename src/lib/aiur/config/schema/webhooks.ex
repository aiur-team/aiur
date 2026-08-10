defmodule Aiur.Config.Schema.Webhooks do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Repos (`"owner/name"`) that are *expected* to deliver webhooks. This is a
    # hint, never a promise: a listed repo starts in `configured_unproven` and
    # keeps polling at full rate until it actually delivers.
    field(:repos, {:array, :string}, default: [])
    # How long a proven repo may stay silent before it degrades back to full
    # polling and raises a needs-attention alert naming the repo.
    field(:silence_threshold_seconds, :integer, default: 900)
    # How often the registry checks proven repos for silence.
    field(:sweep_interval_seconds, :integer, default: 60)
    # Multiplier applied to the base poll interval for repos proven
    # webhook-backed. Defaults to 1.0 so enabling webhook detection changes no
    # interval on its own; widening is the cutover ticket's call. Values below
    # 1.0 are rejected — this dial may only ever slow polling down.
    field(:poll_widen_factor, :float, default: 1.0)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:repos, :silence_threshold_seconds, :sweep_interval_seconds, :poll_widen_factor], empty_values: [])
    |> validate_number(:silence_threshold_seconds, greater_than: 0)
    |> validate_number(:sweep_interval_seconds, greater_than: 0)
    |> validate_number(:poll_widen_factor,
      greater_than_or_equal_to: 1.0,
      message: "must be at least 1.0; webhook mode may only widen the poll interval, never shorten it"
    )
  end
end
