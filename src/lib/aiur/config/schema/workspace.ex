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
    field(:root, :string, default: Path.join(System.tmp_dir!(), "aiur_workspaces"))
    field(:bootstrap_image, :string)
    field(:bootstrap_image_pull, :boolean, default: false)
    field(:wip_max_bytes, :integer, default: 52_428_800)
    field(:wip_max_file_bytes, :integer, default: 10_485_760)
    field(:wip_max_dir_files, :integer, default: 10_000)
    field(:wip_command_timeout_ms, :integer, default: 60_000)
    field(:wip_retention_bytes, :integer, default: 2_147_483_648)
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
