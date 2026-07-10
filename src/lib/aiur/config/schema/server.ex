defmodule Aiur.Config.Schema.Server do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # 0 = bind a free OS-assigned loopback port. The dashboard must bind so
    # claude remote-control's transcript hook can reach it; without a bound
    # port the hook is skipped and RC runs fail `:no_transcript`. Set an
    # explicit port to expose the dashboard at a fixed address.
    field(:port, :integer, default: 0)
    field(:host, :string, default: "127.0.0.1")
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:port, :host], empty_values: [])
    |> validate_number(:port, greater_than_or_equal_to: 0)
  end
end
