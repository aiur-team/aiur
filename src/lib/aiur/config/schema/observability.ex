defmodule Aiur.Config.Schema.Observability do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-16 observability.dashboard_enabled
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail observability.dashboard_enabled | boolean | true | Reserved compatibility setting; use the launch-time `--no-dashboard` flag to suppress the listener in foreground or background mode. |
    field(:dashboard_enabled, :boolean, default: true)
    # Tailscale Funnel status checks are opt-in because Funnel may serve an
    # unrelated target on some hosts.
    # @config-reference config-configuration-16 observability.build_order_funnel_health_check
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail observability.build_order_funnel_health_check | boolean | false | Opts into one bounded startup check of the local Build Order endpoint and configured Tailscale Funnel HTTPS 443 target. Leave disabled when Funnel serves another purpose. |
    field(:build_order_funnel_health_check, :boolean, default: false)
    # Dashboard writes are enabled by default for authenticated operators;
    # set observability.dashboard_writable: false to make them read-only.
    # @config-reference config-configuration-16 observability.dashboard_writable
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail observability.dashboard_writable | boolean | true | Enables dashboard write paths. Set to `false` to disable them. A dashboard bound beyond loopback refuses to start without both dashboard basic-auth environment variables; a loopback listener binds without them and fails closed (see below). |
    field(:dashboard_writable, :boolean, default: true)
    # @config-reference config-configuration-16 observability.refresh_ms
    # @config-detail observability.refresh_ms | integer | 1000 | Dashboard data refresh interval. |
    field(:refresh_ms, :integer, default: 1_000)
    # @config-reference config-configuration-16 observability.render_interval_ms
    # @config-detail observability.render_interval_ms | integer | 16 | Minimum render interval. |
    field(:render_interval_ms, :integer, default: 16)
    # @config-reference config-configuration-16 observability.capture_tags
    # @config-detail observability.capture_tags | map | `%{}` | Static cohort tags; at most 20 string pairs, 64 characters per key/value. |
    field(:capture_tags, :map, default: %{})
    # @config-reference config-configuration-16 observability.capture_label_prefixes
    # @config-detail observability.capture_label_prefixes | list | `["experiment:", "cohort:", "feature:"]` | Label prefixes captured at dispatch; at most 20. |
    field(:capture_label_prefixes, {:array, :string}, default: ["experiment:", "cohort:", "feature:"])
    # @config-reference config-configuration-16 observability.telemetry_enabled
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail observability.telemetry_enabled | boolean | true | Master analytics capture switch; restart to apply. Disabled boots append a local `analytics/capture-gaps.ndjson` marker and `/analytics` shows a capture-off notice. |
    field(:telemetry_enabled, :boolean, default: true)
    # @config-reference config-configuration-16 observability.capture_github_facts
    # @config-detail observability.capture_github_facts | boolean | true | Enables analytics GitHub fact and repo-timeline reads when the master capture switch is on. |
    field(:capture_github_facts, :boolean, default: true)
    # @config-reference config-configuration-16 observability.telemetry_retention_max_bytes
    # @config-detail observability.telemetry_retention_max_bytes | integer | 67108864 | Maximum retained telemetry bytes. |
    field(:telemetry_retention_max_bytes, :integer, default: 64 * 1024 * 1024)
    # @config-reference config-configuration-16 observability.telemetry_retention_max_age_days
    # @config-detail observability.telemetry_retention_max_age_days | integer | 30 | Maximum retained telemetry age. |
    field(:telemetry_retention_max_age_days, :integer, default: 30)
    # @config-reference config-configuration-16 observability.telemetry_retention_prune_interval_bytes
    # @config-detail observability.telemetry_retention_prune_interval_bytes | integer or nil | nil | Bytes between retention-prune checks. |
    field(:telemetry_retention_prune_interval_bytes, :integer)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :dashboard_enabled,
        :build_order_funnel_health_check,
        :dashboard_writable,
        :refresh_ms,
        :render_interval_ms,
        :capture_tags,
        :capture_label_prefixes,
        :telemetry_enabled,
        :capture_github_facts,
        :telemetry_retention_max_bytes,
        :telemetry_retention_max_age_days,
        :telemetry_retention_prune_interval_bytes
      ],
      empty_values: []
    )
    |> validate_change(:capture_tags, &validate_tags/2)
    |> validate_length(:capture_label_prefixes, max: 20)
    |> validate_number(:refresh_ms, greater_than: 0)
    |> validate_number(:render_interval_ms, greater_than: 0)
    |> validate_number(:telemetry_retention_max_bytes, greater_than: 0)
    |> validate_number(:telemetry_retention_max_age_days, greater_than: 0)
    |> validate_number(:telemetry_retention_prune_interval_bytes, greater_than: 0)
  end

  defp validate_tags(field, tags) do
    if map_size(tags) <= 20 and Enum.all?(tags, fn {key, value} -> is_binary(key) and is_binary(value) and String.length(key) <= 64 and String.length(value) <= 64 end),
      do: [],
      else: [{field, "must contain at most 20 string pairs of at most 64 characters"}]
  end
end
