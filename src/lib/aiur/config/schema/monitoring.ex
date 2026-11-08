defmodule Aiur.Config.Schema.Monitoring do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-03 monitoring.daemon_heartbeat_stale_ms
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail monitoring.daemon_heartbeat_stale_ms | integer | 3,600,000 | Threshold in milliseconds for recording a retrospective daemon heartbeat gap on Executor startup. A durable `system.daemon.gap` informational event is emitted only when a stale heartbeat is corroborated by the lifecycle journal; its cause is `clean_shutdown` when a stop was recorded and `unknown` for an unclosed start. Missing heartbeat files are ignored. This is not live monitoring and cannot alert while Aiur is stopped. Default is 1 hour (3,600,000 ms). |
    field(:daemon_heartbeat_stale_ms, :integer, default: 3_600_000)
    # @config-reference config-configuration-03 monitoring.daemon_memory_alert_fraction
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail monitoring.daemon_memory_alert_fraction | float | 0.5 | Share of host memory the daemon's BEAM may use before Aiur raises `system.daemon.memory_high` once, naming the processes that hold the most memory. A `system.daemon.memory_high.resolved` alert follows when usage falls back below the line. Checked every 10 seconds. |
    field(:daemon_memory_alert_fraction, :float, default: 0.5)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:daemon_heartbeat_stale_ms, :daemon_memory_alert_fraction], empty_values: [])
    |> validate_number(:daemon_heartbeat_stale_ms, greater_than: 0)
    |> validate_number(:daemon_memory_alert_fraction, greater_than: 0, less_than_or_equal_to: 1)
  end
end
