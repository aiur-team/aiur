defmodule Aiur.Machine.Settings.Schema.Coordination do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Machine.Settings.Validation

  @primary_key false
  embedded_schema do
    field(:database_url_env, :string, default: "AIUR_LEASE_DATABASE_URL")
    field(:offline_after_seconds, :integer, default: 180)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> Validation.cast(attrs)
    |> validate_format(:database_url_env, ~r/\A[A-Z_][A-Z0-9_]*\z/, message: "must be an environment variable name")
    |> validate_number(:offline_after_seconds, greater_than_or_equal_to: 30, less_than_or_equal_to: 86_400)
  end
end
