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
    # @config-reference config-configuration-03 monitoring.disk_alert_percent
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail monitoring.disk_alert_percent | integer | 90 | Used-space percentage on the filesystem holding `workspace.root`, the run-log root or `~/.aiur` at which Aiur raises `system.disk.pressure` once, naming the filesystem, its use, free bytes and the largest workspace directories. `system.disk.pressure.resolved` follows when usage falls back below the line. Checked every minute. |
    field(:disk_alert_percent, :integer, default: 90)
    # @config-reference config-configuration-03 monitoring.disk_stop_dispatch_percent
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail monitoring.disk_stop_dispatch_percent | integer | 97 | Used-space percentage on any watched filesystem at which Aiur stops starting new agents, so a full disk does not crash the daemon. Running agents continue. `aiur status` shows the `DISK` line and a `disk` admission hold. Dispatch also stops below `monitoring.disk_stop_dispatch_free_gb` free. Dispatch resumes once usage is 2 points below the line and free space is 2% of the filesystem above the floor, so a disk hovering on the line does not start an agent every minute. A failed, timed-out or stale free-space sample shows as `unknown` or `stale` and does not stop dispatch. Must be at least `monitoring.disk_alert_percent`. |
    field(:disk_stop_dispatch_percent, :integer, default: 97)
    # @config-reference config-configuration-03 monitoring.disk_stop_dispatch_free_gb
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail monitoring.disk_stop_dispatch_free_gb | integer | 10 | Free space in GiB below which Aiur stops starting new agents on any watched filesystem, whatever its used percentage, because a percentage alone is too loose on a small disk and too strict on a large one. Dispatch stops when either this floor or `monitoring.disk_stop_dispatch_percent` is crossed. `0` disables the floor. |
    field(:disk_stop_dispatch_free_gb, :integer, default: 10)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:daemon_heartbeat_stale_ms, :daemon_memory_alert_fraction, :disk_alert_percent, :disk_stop_dispatch_percent, :disk_stop_dispatch_free_gb], empty_values: [])
    |> validate_number(:daemon_heartbeat_stale_ms, greater_than: 0)
    |> validate_number(:daemon_memory_alert_fraction, greater_than: 0, less_than_or_equal_to: 1)
    |> validate_number(:disk_alert_percent, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:disk_stop_dispatch_percent, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:disk_stop_dispatch_free_gb, greater_than_or_equal_to: 0)
    |> validate_disk_order()
  end

  defp validate_disk_order(changeset) do
    if get_field(changeset, :disk_stop_dispatch_percent) < get_field(changeset, :disk_alert_percent),
      do: add_error(changeset, :disk_stop_dispatch_percent, "must be at least monitoring.disk_alert_percent"),
      else: changeset
  end
end
