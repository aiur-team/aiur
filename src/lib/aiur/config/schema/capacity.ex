defmodule Aiur.Config.Schema.Capacity do
  @moduledoc """
  Project (L3) tightening of the machine capacity policy. Only `limits`,
  `reserve.percent` and `last_resort` are accepted; `Aiur.Capacity.TightenCheck`
  refuses a value that loosens `~/.aiur/machine`.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Capacity.PolicyConfig

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field(:sources, :map, default: %{})
    field(:limits, :map, default: %{})
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:sources, :limits])
    |> validate_change(:sources, &PolicyConfig.source_errors(&1, &2, :project))
    |> validate_change(:limits, &PolicyConfig.limit_errors/2)
  end
end
