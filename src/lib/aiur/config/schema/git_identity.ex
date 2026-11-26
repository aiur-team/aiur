defmodule Aiur.Config.Schema.GitIdentity do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Unset fields fall back to the `tracker.github.bot_account` login; see
    # `Aiur.AgentEnvironment.GitIdentity`.
    # @config-reference config-configuration-agent-00 agent.git_identity.name, agent.git_identity.email
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail agent.git_identity.name, agent.git_identity.email | string or nil | nil | Author and committer of agent commits on every backend. Aiur exports them as `GIT_AUTHOR_*` and `GIT_COMMITTER_*`, which override the operator's git config. An unset field uses the `tracker.github.bot_account` login, or `<login>@users.noreply.github.com`; with neither set, commits use `Aiur Agent <aiur-agent@users.noreply.github.com>` and the daemon logs one warning. Local workspaces also get a `commit-msg` hook that rejects AI co-author trailers and generated-with footers, and Claude settings that stop the CLI adding them. |
    field(:name, :string)
    field(:email, :string)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:name, :email])
    # Both values travel in environment variables and a shell export prefix.
    |> validate_format(:name, ~r/\A[^\r\n<>]+\z/)
    |> validate_format(:email, ~r/\A[^\s<>]+@[^\s<>]+\z/)
  end
end
