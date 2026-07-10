defmodule Aiur.Config.Schema.Opencode do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:command, :string, default: "opencode")
    field(:bridge_port, :integer, default: 4097)
    field(:bridge_host, :string, default: "127.0.0.1")
    field(:serve_args, {:array, :string}, default: [])
    field(:model_prefix, :string, default: "aiur")
    field(:prewarm_disabled, :boolean, default: false)
  end

  @fields [:command, :bridge_port, :bridge_host, :serve_args, :model_prefix, :prewarm_disabled]

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, @fields, empty_values: [])
    |> validate_number(:bridge_port, greater_than_or_equal_to: 0, less_than: 65_536)
    |> validate_length(:bridge_host, min: 1)
    |> validate_length(:model_prefix, min: 1)
  end
end
