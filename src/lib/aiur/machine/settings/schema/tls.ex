defmodule Aiur.Machine.Settings.Schema.Tls do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Machine.Settings.Validation
  @primary_key false
  embedded_schema do
    field(:cert_file, :string)
    field(:key_file, :string)
    field(:bind_host, :string)
    field(:advertise_host, :string)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> Validation.cast(attrs, nullable: true)
    |> update_change(:cert_file, &expand/1)
    |> update_change(:key_file, &expand/1)
    |> validate_change(:bind_host, fn key, value -> Validation.check(key, Validation.ip?(value), "must be an IP literal") end)
    |> validate_change(:advertise_host, fn key, value -> Validation.check(key, Validation.dns?(value), "must be a DNS name without scheme or port") end)
  end

  defp expand(nil), do: nil
  defp expand(path), do: Path.expand(path)
end
