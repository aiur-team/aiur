defmodule Aiur.Config.Schema.Hooks do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-07 hooks.after_create
    # @config-detail hooks.after_create | string or nil | nil | Command after workspace creation. |
    field(:after_create, :string)
    # @config-reference config-configuration-07 hooks.before_run
    # @config-detail hooks.before_run | string or nil | nil | Command before each agent run. |
    field(:before_run, :string)
    # @config-reference config-configuration-07 hooks.after_run
    # @config-detail hooks.after_run | string or nil | nil | Command after each agent run. |
    field(:after_run, :string)
    # @config-reference config-configuration-07 hooks.before_remove
    # @config-detail hooks.before_remove | string or nil | nil | Command before workspace removal. |
    field(:before_remove, :string)
    # @config-reference config-configuration-07 hooks.timeout_ms
    # @config-detail hooks.timeout_ms | integer | 600000 | Per-hook timeout; 10 minutes by default. |
    field(:timeout_ms, :integer, default: 600_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
    |> validate_number(:timeout_ms, greater_than: 0)
  end
end
