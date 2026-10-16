defmodule Aiur.Config.Schema.Opencode do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-19 opencode.command
    # @config-detail opencode.command | string | `opencode` | Command launching opencode. |
    field(:command, :string, default: "opencode")
    # @config-reference config-configuration-19 opencode.bridge_port
    # @config-detail opencode.bridge_port | integer | 4097 | Aiur↔opencode bridge port. |
    field(:bridge_port, :integer, default: 4097)
    # @config-reference config-configuration-19 opencode.bridge_host
    # @config-detail opencode.bridge_host | string | `127.0.0.1` | Aiur↔opencode bridge host. |
    field(:bridge_host, :string, default: "127.0.0.1")
    # @config-reference config-configuration-19 opencode.serve_args
    # @config-detail opencode.serve_args | array | `[]` | Extra `opencode serve` arguments. |
    field(:serve_args, {:array, :string}, default: [])
    # @config-reference config-configuration-19 opencode.model_prefix
    # @config-detail opencode.model_prefix | string | `aiur` | Prefix for registered synthetic models. |
    field(:model_prefix, :string, default: "aiur")
    # @config-reference config-configuration-19 opencode.prewarm_disabled
    # @config-detail opencode.prewarm_disabled | boolean | false | Disables opencode session pre-warming. |
    field(:prewarm_disabled, :boolean, default: false)
  end

  @fields [:command, :bridge_port, :bridge_host, :serve_args, :model_prefix, :prewarm_disabled]

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, @fields, empty_values: [])
    |> validate_number(:bridge_port, greater_than_or_equal_to: 0, less_than: 65_536)
    |> validate_length(:bridge_host, min: 1)
    |> validate_length(:model_prefix, min: 1)
  end
end
