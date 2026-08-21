defmodule Aiur.Config.Schema.GithubApp do
  @moduledoc """
  The optional GitHub App identity under `tracker.github.github_app`.

  `tracker.github.bot_account` names the login **agents** publish as — the
  account that pushes branches, opens pull requests, and whose authorship the
  merge policy depends on. When the daemon additionally authenticates with a
  GitHub App installation token it writes as a *different* login, the App's bot
  user (`<app-slug>[bot]`). One key cannot truthfully name both: pointing
  `bot_account` at the App bot makes every agent-authorship check demand an
  identity no agent holds, and pointing it at the agent account leaves the
  daemon reacting to its own comments.

  This block carries the daemon-side identity so each side can name its own.
  It is entirely optional: with no `github_app` configured,
  `Aiur.GitHub.Config.daemon_account/0` falls back to `bot_account` and the
  single-identity deployment behaves exactly as it did before.

  Only the login lives here. The App *credentials* stay in the environment
  (`GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY_PATH`)
  where `Aiur.GitHub.AppCredentials` reads them, so no private key material is
  ever written to the config file.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @bot_suffix "[bot]"

  @primary_key false
  embedded_schema do
    field(:account, :string)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:account], empty_values: [])
    |> validate_app_bot_login()
  end

  # A GitHub App installation token can only ever write as `<app-slug>[bot]`, so
  # a value without that suffix names an account this block can never be. Caught
  # at config load, where the operator is looking at the key, rather than as a
  # runtime identity mismatch discovered from the daemon replying to itself.
  # A blank value is "unset" and passes; `Aiur.GitHub.Config.app_account/0`
  # normalizes it back to `nil`.
  defp validate_app_bot_login(changeset) do
    validate_change(changeset, :account, fn :account, account ->
      trimmed = account |> to_string() |> String.trim()

      if trimmed == "" or String.ends_with?(String.downcase(trimmed), @bot_suffix),
        do: [],
        else: [account: "must be the GitHub App bot login, `<app-slug>[bot]`"]
    end)
  end
end
