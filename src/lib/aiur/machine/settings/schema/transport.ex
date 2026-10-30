defmodule Aiur.Machine.Settings.Schema.Transport do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Machine.Settings.{Schema.Tls, Validation}
  @primary_key false
  embedded_schema do
    embeds_one(:tls, Tls, defaults_to_struct: true, on_replace: :update)
    field(:allow_cleartext_overlay, :boolean, default: false)
    field(:cleartext_overlay_cidrs, {:array, :string}, default: ["100.64.0.0/10", "fd7a:115c:a1e0::/48"])
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> Validation.cast(attrs)
    |> validate_change(:cleartext_overlay_cidrs, fn key, values ->
      Validation.check(key, Enum.all?(values, &Validation.cidr?/1), "must contain IPv4/IPv6 CIDRs with a nonzero prefix")
    end)
  end
end
