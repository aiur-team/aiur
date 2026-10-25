defmodule Aiur.Config.Schema.Upgrade do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # The `aiur run` version notice (and its registry phone-home) is optional by
    # design — outbound integrations are always opt-out in Aiur. Defaults to
    # true; set to false to suppress the check entirely (zero outbound calls).
    # @config-reference config-configuration-12 upgrade.check_enabled
    # @config-detail upgrade.check_enabled | boolean | true | Enables the `aiur run` version notice and its registry check. Set false to suppress the check entirely (zero outbound calls). |
    field(:check_enabled, :boolean, default: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:check_enabled], empty_values: [])
  end
end
