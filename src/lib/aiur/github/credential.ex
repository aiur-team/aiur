defmodule Aiur.GitHub.Credential do
  @moduledoc """
  One resolvable GitHub credential: an identity, a kind, and a way to get its
  token.

  The struct deliberately holds no secret. `token/1` resolves the secret at the
  moment of use, because the App installation credential's token is short-lived
  and rotated underneath us by `Aiur.GitHub.AppTokenRefresher`; a token captured
  into a registry entry at boot would be stale within the hour.

  `writes?` is the identity boundary, not a performance flag. A credential that
  cannot write is still fully useful — the burn that exhausts the budget is
  polling, which is all reads — and keeping writes pinned to their correct
  identity is what preserves the agent-authors / human-reviews separation the
  repository already depends on.
  """

  alias Aiur.GitHub.{AppTokenRefresher, Budget}
  alias Aiur.GitHub.Config, as: GitHubConfig

  @enforce_keys [:id, :kind]
  defstruct [:id, :kind, :identity, :token_env, source: :env, writes?: false, primary?: false]

  @type kind :: :app_installation | :machine_user | :human
  @type source :: :legacy | :app | :env
  @type intent :: :read | :write

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          identity: String.t() | nil,
          token_env: String.t() | nil,
          source: source(),
          writes?: boolean(),
          primary?: boolean()
        }

  @doc """
  Resolves the credential's current token, or `nil` when it is unavailable.

  An unavailable credential is not an error here: an operator who has configured
  a PAT env var that is not exported on this host should lose that credential
  from the pool, not lose the daemon.
  """
  @spec token(t()) :: String.t() | nil
  # The legacy credential is whatever the single-credential path already
  # resolves, keyring fallback and boot-time cache included. Re-deriving it from
  # the environment here would quietly drop the `gh` keyring fallback.
  def token(%__MODULE__{source: :legacy}), do: normalize(GitHubConfig.token())

  def token(%__MODULE__{kind: :app_installation}), do: normalize(AppTokenRefresher.current_token())

  def token(%__MODULE__{token_env: env}) when is_binary(env), do: normalize(System.get_env(env))

  def token(%__MODULE__{}), do: nil

  @doc "The broker's one-way key for this credential's current token, or `nil`."
  @spec token_key(t()) :: String.t() | nil
  def token_key(%__MODULE__{} = credential) do
    case token(credential) do
      token when is_binary(token) -> Budget.token_key(token)
      _unavailable -> nil
    end
  end

  @doc """
  Whether the credential may carry traffic of this intent.

  Every configured credential is read-eligible. Write eligibility is opt-in and
  a `human` credential can never hold it (see
  `Aiur.Config.Schema.GithubCredential`).
  """
  @spec eligible?(t(), intent()) :: boolean()
  def eligible?(%__MODULE__{}, :read), do: true
  def eligible?(%__MODULE__{kind: :human}, :write), do: false
  def eligible?(%__MODULE__{writes?: writes?}, :write), do: writes?

  @doc "A log/report-safe description. Never includes the token."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = credential) do
    identity = credential.identity || "unknown-identity"
    "#{credential.id} (#{credential.kind}, #{identity}, #{if credential.writes?, do: "read+write", else: "read-only"})"
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil
end
