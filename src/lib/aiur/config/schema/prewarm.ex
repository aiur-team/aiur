defmodule Aiur.Config.Schema.Prewarm do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-08 prewarm.enabled
    # @config-detail prewarm.enabled | boolean | false | Opts into one warm base checkout. |
    field(:enabled, :boolean, default: false)
    # base_build is the one-time base build command. It is usually NOT written
    # inline: `base_build_file` points at a sibling script (`.aiur/prewarm`)
    # whose contents `Aiur.Workflow` reads into `base_build`, keeping the
    # multi-line shell out of the main config (mirrors `hooks_file`).
    # @config-reference config-configuration-08 prewarm.base_build
    # @config-detail prewarm.base_build | string | none | One-time base build command. |
    field(:base_build, :string)
    # @config-reference config-configuration-08 prewarm.base_build_file
    # @config-detail prewarm.base_build_file | string | none | Sibling script loaded into `base_build`. |
    field(:base_build_file, :string)
    # @config-reference config-configuration-08 prewarm.poll_seconds
    # @config-detail prewarm.poll_seconds | integer | 0 | Base-refresh interval; 0 disables polling. |
    field(:poll_seconds, :integer, default: 0)
    # @config-reference config-configuration-08 prewarm.build_timeout_minutes
    # @config-detail prewarm.build_timeout_minutes | integer | 60 | Total time allowed for a base clone, fetch, and build. |
    field(:build_timeout_minutes, :integer, default: 60)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :base_build, :base_build_file, :poll_seconds, :build_timeout_minutes], empty_values: [])
    |> validate_number(:poll_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:build_timeout_minutes, greater_than: 0)
  end
end
