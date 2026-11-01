defmodule Aiur.Config.Schema.Toolchain do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-toolchain toolchain.auto_update
    # @config-detail toolchain.auto_update | boolean | false | Updates behind npm-managed `aiur-claude`, `claude` and `codex` installs while none of their workers run; never an `npm link`. |
    field(:auto_update, :boolean, default: false)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs), do: cast(schema, attrs, [:auto_update], empty_values: [])
end
