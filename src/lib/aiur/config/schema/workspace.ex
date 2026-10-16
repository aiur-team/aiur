defmodule Aiur.Config.Schema.Workspace do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # Bounds of the uncommitted-work save that runs before Aiur deletes or
  # recreates a dirty workspace (#2743). See `Aiur.Workspace.WipPreservation`.
  @wip_fields [
    :wip_max_bytes,
    :wip_max_file_bytes,
    :wip_max_dir_files,
    :wip_command_timeout_ms,
    :wip_retention_bytes,
    :wip_retention_days
  ]

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-05 workspace.root
    # @config-detail workspace.root | string path | tmp `aiur_workspaces` | Root for agent workspaces. |
    field(:root, :string, default: Path.join(System.tmp_dir!(), "aiur_workspaces"))
    # @config-reference config-configuration-05 workspace.bootstrap_image
    # @config-detail workspace.bootstrap_image | string | nil | Docker image for warm build-cache seeding. |
    field(:bootstrap_image, :string)
    # @config-reference config-configuration-05 workspace.bootstrap_image_pull
    # @config-detail workspace.bootstrap_image_pull | boolean | false | Pulls the bootstrap image before seeding. |
    field(:bootstrap_image_pull, :boolean, default: false)
    # @config-reference config-configuration-05 workspace.wip_max_bytes
    # @config-detail workspace.wip_max_bytes | integer | 52428800 | Cap in bytes of one save of uncommitted work (50 MiB). Untracked files past it are skipped; the tracked patch is always kept. |
    field(:wip_max_bytes, :integer, default: 52_428_800)
    # @config-reference config-configuration-05 workspace.wip_max_file_bytes
    # @config-detail workspace.wip_max_file_bytes | integer | 10485760 | An untracked file larger than this (10 MiB) is skipped in a save. |
    field(:wip_max_file_bytes, :integer, default: 10_485_760)
    # @config-reference config-configuration-05 workspace.wip_max_dir_files
    # @config-detail workspace.wip_max_dir_files | integer | 10000 | An untracked directory with more files than this, or a nested repository, is skipped whole. |
    field(:wip_max_dir_files, :integer, default: 10_000)
    # @config-reference config-configuration-05 workspace.wip_command_timeout_ms
    # @config-detail workspace.wip_command_timeout_ms | integer | 60000 | Time limit of each `git` and `tar` command of a save. A timeout keeps the workspace, except for a closed ticket. |
    field(:wip_command_timeout_ms, :integer, default: 60_000)
    # @config-reference config-configuration-05 workspace.wip_retention_bytes
    # @config-detail workspace.wip_retention_bytes | integer | 2147483648 | Cap in bytes of all of `wip-preserved/` (2 GiB). Closed tickets' saves are pruned first. |
    field(:wip_retention_bytes, :integer, default: 2_147_483_648)
    # @config-reference config-configuration-05 workspace.wip_retention_days
    # @config-detail workspace.wip_retention_days | integer | 14 | Saves older than this are pruned. The newest save of an open ticket is never pruned. |
    field(:wip_retention_days, :integer, default: 14)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    changeset =
      schema
      |> cast(attrs, [:root, :bootstrap_image, :bootstrap_image_pull | @wip_fields], empty_values: [])
      |> validate_length(:bootstrap_image, min: 1)

    Enum.reduce(@wip_fields, changeset, &validate_number(&2, &1, greater_than: 0))
  end
end
