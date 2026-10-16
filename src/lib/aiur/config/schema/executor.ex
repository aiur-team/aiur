defmodule Aiur.Config.Schema.ExecutorSweep do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:unreviewed_pr_minutes, :integer, default: 10)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:unreviewed_pr_minutes])
    |> validate_number(:unreviewed_pr_minutes, greater_than: 0)
    |> validate_raw_positive_integer(attrs)
  end

  defp validate_raw_positive_integer(changeset, attrs) do
    case Map.get(attrs, "unreviewed_pr_minutes") do
      nil -> changeset
      value when is_integer(value) and value > 0 -> changeset
      _value -> add_error(changeset, :unreviewed_pr_minutes, "must be a positive integer")
    end
  end
end

defmodule Aiur.Config.Schema.Executor do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Config.Schema.ExecutorSweep

  @primary_key false
  embedded_schema do
    embeds_one(:sweep, ExecutorSweep, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [])
    |> cast_embed(:sweep, with: &ExecutorSweep.changeset/2)
  end
end
