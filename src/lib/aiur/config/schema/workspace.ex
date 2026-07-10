defmodule Aiur.Config.Schema.Workspace do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:root, :string, default: Path.join(System.tmp_dir!(), "aiur_workspaces"))
    field(:bootstrap_image, :string)
    field(:bootstrap_image_pull, :boolean, default: false)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:root, :bootstrap_image, :bootstrap_image_pull], empty_values: [])
    |> validate_length(:bootstrap_image, min: 1)
  end
end
