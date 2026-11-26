defmodule Aiur.Config.Schema.PrHealth do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Opt-in, like pr_watch. When false the PR-health scanner does not run, so
    # a repo that has not configured thresholds pays no GitHub API budget.
    # @config-reference config-configuration-10 pr_health.enabled
    # @config-detail pr_health.enabled | boolean | false | Enables the PR-health scan and the rework re-queue. |
    field(:enabled, :boolean, default: false)
    # How often the scanner lists open PRs and checks the age/unmergeable
    # conditions. The open-PR list is a conditional read, so steady state is a
    # 304 that costs nothing against the primary REST limit.
    # @config-reference config-configuration-10 pr_health.interval_seconds
    # @config-detail pr_health.interval_seconds | integer | 1800 | How often the scan lists open PRs. |
    field(:interval_seconds, :integer, default: 1800)
    # A non-draft PR older than this many hours with no completed review is
    # flagged as awaiting review (Cause 3 of #2337).
    # @config-reference config-configuration-10 pr_health.stale_hours
    # @config-detail pr_health.stale_hours | integer | 24 | A non-draft PR older than this with no review is flagged. |
    field(:stale_hours, :integer, default: 24)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :interval_seconds, :stale_hours], empty_values: [])
    |> validate_number(:interval_seconds, greater_than: 0)
    |> validate_number(:stale_hours, greater_than: 0)
  end
end
