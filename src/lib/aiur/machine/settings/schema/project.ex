defmodule Aiur.Machine.Settings.Schema.Project do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Aiur.Machine.Settings.Validation

  # The checkout path is machine-local; keep it out of inspect output and logs.
  @derive {Inspect, except: [:config]}
  @primary_key false
  embedded_schema do
    field(:repo, :string)
    field(:config, :string)
    field(:max_agents, :integer)
    field(:priority, :integer)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> Validation.cast(attrs, nullable: true)
    |> validate_required([:repo, :config])
    |> validate_format(:repo, ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, message: "must be owner/name")
    |> validate_format(:config, ~r/\A(\/|~\/)/, message: "must be an absolute path")
    |> update_change(:config, &Path.expand/1)
    |> validate_number(:max_agents, greater_than_or_equal_to: 1)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
  end
end
