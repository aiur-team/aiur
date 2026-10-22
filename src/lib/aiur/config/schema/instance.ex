defmodule Aiur.Config.Schema.Instance do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-00 instance.role
    # @config-detail instance.role | string | `primary` | `secondary` disables repository-wide landing, quarantine, merge-queue and main-branch watchers while retaining ticket dispatch and per-ticket CI handling. Read once at daemon start; change it with a restart. |
    field(:role, :string, default: "primary")
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema |> cast(attrs, [:role], empty_values: []) |> validate_inclusion(:role, ["primary", "secondary"])
  end
end
