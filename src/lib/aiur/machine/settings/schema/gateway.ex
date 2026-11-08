defmodule Aiur.Machine.Settings.Schema.Gateway do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Machine.Settings.Validation

  @primary_key false
  embedded_schema do
    field(:host, :string, default: "127.0.0.1")
    field(:port, :integer, default: 4710)
    field(:endpoints, {:array, :string}, default: [])
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> Validation.cast(attrs)
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65_535, message: "must be fixed so paired phones keep a valid endpoint (1..65535)")
    |> validate_change(:host, fn key, host -> Validation.check(key, Validation.resolvable?(host), "must be an IP or resolvable host") end)
    |> validate_change(:endpoints, fn key, urls -> Validation.check(key, Enum.all?(urls, &Validation.endpoint?/1), "must contain absolute HTTP(S) URLs without path, query or fragment") end)
  end
end
