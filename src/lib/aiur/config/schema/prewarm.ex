defmodule Aiur.Config.Schema.Prewarm do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:enabled, :boolean, default: false)
    # base_build is the one-time base build command. It is usually NOT written
    # inline: `base_build_file` points at a sibling script (`.aiur/prewarm`)
    # whose contents `Aiur.Workflow` reads into `base_build`, keeping the
    # multi-line shell out of the main config (mirrors `hooks_file`).
    field(:base_build, :string)
    field(:base_build_file, :string)
    field(:poll_seconds, :integer, default: 0)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :base_build, :base_build_file, :poll_seconds], empty_values: [])
    |> validate_number(:poll_seconds, greater_than_or_equal_to: 0)
  end
end
