defmodule Aiur.Config.Schema.Webhooks do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Repos (`"owner/name"`) that are *expected* to deliver webhooks. This is a
    # hint, never a promise: a listed repo starts in `configured_unproven` and
    # keeps polling at full rate until it actually delivers.
    # @config-reference config-configuration-04 webhooks.repos
    # @config-detail webhooks.repos | list of `owner/name` | `[]` | Repos expected to deliver webhooks. A hint only. A listed repo keeps polling at full rate until it actually delivers. |
    field(:repos, {:array, :string}, default: [])
    # How long a proven repo may stay silent before it degrades back to full
    # polling and raises a needs-attention alert naming the repo.
    # @config-reference config-configuration-04 webhooks.silence_threshold_seconds
    # @config-detail webhooks.silence_threshold_seconds | integer | 900 | How long a proven repo may go without a delivery before it degrades back to full polling and raises a needs-attention alert. |
    field(:silence_threshold_seconds, :integer, default: 900)
    # How often the registry checks proven repos for silence.
    # @config-reference config-configuration-04 webhooks.sweep_interval_seconds
    # @config-detail webhooks.sweep_interval_seconds | integer | 60 | How often proven repos are checked for silence. |
    field(:sweep_interval_seconds, :integer, default: 60)
    # Multiplier applied to the base poll interval for repos proven
    # webhook-backed. Values below 1.0 are rejected — this dial may only ever
    # slow polling down.
    #
    # 2.0 is the cutover's first step (#1680), deliberately one step and not a
    # jump: with the 120s base it puts a proven repo on a 240s reconciliation
    # sweep. It applies only to a repo that has actually delivered, so a repo
    # that is merely configured — or that has gone silent and been degraded by
    # the sweep — polls at the base interval exactly as it did before webhooks
    # existed. Widen further only after a fleet measurement at the current step.
    # @config-reference config-configuration-04 webhooks.poll_widen_factor
    # @config-detail webhooks.poll_widen_factor | float | 2.0 | Multiplier applied to `polling.interval_seconds` for repos proven webhook-backed. Values below 1.0 are rejected. |
    field(:poll_widen_factor, :float, default: 2.0)
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
