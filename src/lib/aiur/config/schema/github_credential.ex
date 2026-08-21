defmodule Aiur.Config.Schema.GithubCredential do
  @moduledoc """
  One entry in `tracker.github.credentials` — a GitHub credential the daemon may
  spend API budget on.

  Leaving the list empty is the supported single-credential configuration: the
  daemon resolves exactly one credential the way it always has (App installation
  token when the App environment is configured, otherwise `GITHUB_TOKEN`).
  Listing credentials only adds *alternatives*; it never removes the default.

  `kind` is not decoration. A `human` credential belongs to a person, and every
  write GitHub records against it is attributed to that person: their name on the
  comment, their name in the audit trail, their account inside GitHub's
  machine-user terms. Aiur also depends on identity separation — agent PRs author
  as the machine user and a human reviews them — so borrowing a human's token for
  a write can make a PR unmergeable by its own reviewer. A `human` credential is
  therefore read-only and the changeset refuses `writes: true` rather than
  quietly downgrading it, so the misconfiguration is visible at config load.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @kinds ~w(app_installation machine_user human)

  @primary_key false
  embedded_schema do
    field(:id, :string)
    field(:kind, :string, default: "machine_user")
    field(:identity, :string)
    field(:token_env, :string)
    field(:writes, :boolean, default: false)
    field(:enabled, :boolean, default: true)
  end

  @doc "The credential kinds `kind` accepts."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :kind, :identity, :token_env, :writes, :enabled], empty_values: [])
    |> validate_required([:id, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_identifier()
    |> validate_token_source()
    |> validate_human_read_only()
  end

  defp validate_identifier(changeset) do
    validate_format(changeset, :id, ~r/\A[a-z0-9][a-z0-9_-]*\z/,
      message: "must be a lowercase identifier (letters, digits, dash, underscore)"
    )
  end

  # An App installation credential mints its own token through the refresher, so
  # it names no environment variable. Everything else must say where its secret
  # comes from; a credential with no token source would silently never be
  # selected, which reads as "pooling is not working" rather than as a config
  # error.
  defp validate_token_source(changeset) do
    case get_field(changeset, :kind) do
      "app_installation" -> changeset
      _pat -> validate_required(changeset, [:token_env])
    end
  end

  defp validate_human_read_only(changeset) do
    if get_field(changeset, :kind) == "human" and get_field(changeset, :writes) == true do
      add_error(
        changeset,
        :writes,
        "a human credential cannot be used for writes — GitHub attributes the write to that person and it breaks agent/reviewer identity separation"
      )
    else
      changeset
    end
  end
end
