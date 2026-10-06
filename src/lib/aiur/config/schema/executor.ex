defmodule Aiur.Config.Schema.Executor do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:relay_operator_answers, :boolean, default: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:relay_operator_answers], empty_values: [])
  end
end
