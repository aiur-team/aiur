defmodule Aiur.Config.Schema.DashboardAuth.Google do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-22 dashboard_auth.google.allowed_emails
    # @config-detail dashboard_auth.google.allowed_emails | array | `[]` | Exact email allowlist for Google OpenID Connect; an empty list disables Google sign-in. |
    field(:allowed_emails, {:array, :string}, default: [])
  end

  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:allowed_emails], empty_values: [])
    |> validate_change(:allowed_emails, fn :allowed_emails, emails ->
      if Enum.all?(emails, &valid_email?/1), do: [], else: [allowed_emails: "must contain valid email addresses"]
    end)
  end

  defp valid_email?(email), do: is_binary(email) and String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
end

defmodule Aiur.Config.Schema.DashboardAuth do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.Schema.DashboardAuth.Google

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-22 dashboard_auth.passkeys
    # @config-detail dashboard_auth.passkeys | boolean | false | Enables passkey login and enrollment after a fresh Google sign-in. |
    field(:passkeys, :boolean, default: false)
    # @config-reference config-configuration-22 dashboard_auth.session_max_age_days
    # @config-detail dashboard_auth.session_max_age_days | integer | 30 | Maximum dashboard browser session age in days. |
    field(:session_max_age_days, :integer, default: 30)
    # @config-reference config-configuration-22 dashboard_auth.browser_basic_auth
    # @config-detail dashboard_auth.browser_basic_auth | boolean | true | Allows Basic Auth fallback on browser pages; API and Stream Deck machine clients keep Basic Auth. |
    field(:browser_basic_auth, :boolean, default: true)
    embeds_one(:google, Google, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:passkeys, :session_max_age_days, :browser_basic_auth], empty_values: [])
    |> cast_embed(:google, with: &Google.changeset/2)
    |> validate_number(:session_max_age_days, greater_than: 0, less_than_or_equal_to: 365)
  end
end
