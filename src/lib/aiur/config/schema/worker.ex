defmodule Aiur.Config.Schema.Worker do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-06 worker.ssh_hosts
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail worker.ssh_hosts | array | `[]` | SSH hosts available for remote execution. Each server must allow `BASH_ENV`, `ENV`, `HOME`, and `ZDOTDIR` through OpenSSH `AcceptEnv`; Aiur neutralizes them before the account shell starts and fails closed if the server rejects them. |
    field(:ssh_hosts, {:array, :string}, default: [])
    # @config-reference config-configuration-06 worker.max_concurrent_agents_per_host
    # @config-detail worker.max_concurrent_agents_per_host | integer or nil | nil | Per-host concurrent-agent cap. |
    field(:max_concurrent_agents_per_host, :integer)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
    |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
  end
end
