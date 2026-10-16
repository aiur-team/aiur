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
    # @config-reference config-configuration-01 tracker.github.credentials.id
    # @config-detail tracker.github.credentials.id | string | required | Lowercase identifier naming this credential in `aiur github-usage` and `aiur github-cost`. Must be unique. |
    field(:id, :string)
    # @config-reference config-configuration-01 tracker.github.credentials.kind
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.credentials.kind | string | `machine_user` | One of `app_installation`, `machine_user` or `human`. Set it to `human` for a real person's token so Aiur keeps writes off that identity. |
    field(:kind, :string, default: "machine_user")
    # @config-reference config-configuration-01 tracker.github.credentials.identity
    # @config-detail tracker.github.credentials.identity | string | nil | The GitHub login this credential authenticates as. Reporting only, so a usage row names an account rather than a hash. |
    field(:identity, :string)
    # @config-reference config-configuration-01 tracker.github.credentials.token_env
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.credentials.token_env | string | required except for `app_installation` | Environment variable holding the token. An `app_installation` credential mints its own and needs none. A variable that is not exported drops the credential from the pool rather than failing boot. |
    field(:token_env, :string)
    # @config-reference config-configuration-01 tracker.github.credentials.writes
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.credentials.writes | boolean | `false` | Whether this credential may carry writes (comments, labels, merges, PR creation). A `human` credential cannot be set to `true`: GitHub attributes the write to that person and it breaks the agent-authors / human-reviews separation the merge policy depends on. |
    field(:writes, :boolean, default: false)
    # @config-reference config-configuration-01 tracker.github.credentials.enabled
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.credentials.enabled | boolean | `true` | Set to `false` to keep a credential in the file but out of the pool, for a token being rotated or an account temporarily rate-limited. |
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
    validate_format(changeset, :id, ~r/\A[a-z0-9][a-z0-9_-]*\z/, message: "must be a lowercase identifier (letters, digits, dash, underscore)")
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
