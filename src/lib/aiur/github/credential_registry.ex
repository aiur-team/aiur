defmodule Aiur.GitHub.CredentialRegistry do
  @moduledoc """
  The set of GitHub credentials the daemon may spend budget on.

  Before this module there was one credential and one `:persistent_term` slot
  holding it (`Aiur.GitHub.Config.token/0`). The registry replaces that single
  slot with a resolvable *set*, without changing what a single-credential
  deployment does: when `tracker.github.credentials` is empty — the default —
  the registry contains exactly one entry, the legacy credential, and it
  delegates to the same `Config.token/0` path. Nothing about ordering,
  fallback, or the App-vs-PAT decision moves.

  Configured credentials are appended after the legacy one. The legacy
  credential stays first and stays `primary?`, so every tie in the selector
  resolves to the credential the daemon would have used anyway.

  A configured credential whose token does not resolve on this host (env var not
  exported) is dropped from the pool with a one-time warning rather than
  failing boot. Losing an alternative credential should degrade capacity, never
  availability.
  """

  alias Aiur.Config
  alias Aiur.GitHub.AppCredentials
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Credential

  require Logger

  @legacy_id "primary"

  @doc """
  Every credential with a resolvable token, legacy first.

  `:credentials` in `opts` is the test seam and takes precedence over config.
  """
  @spec credentials(keyword()) :: [Credential.t()]
  def credentials(opts \\ []) do
    opts
    |> configured()
    |> Enum.filter(&resolvable?/1)
  end

  @doc """
  Every configured credential, resolvable or not.

  Reporting wants the unresolvable ones too: "configured but its token is not on
  this host" is the answer to why the pool is smaller than the operator expects,
  and a report that silently omits the row cannot say it.
  """
  @spec configured(keyword()) :: [Credential.t()]
  def configured(opts \\ []) do
    case Keyword.fetch(opts, :credentials) do
      {:ok, credentials} when is_list(credentials) -> credentials
      _absent -> [legacy_credential() | Enum.map(configured_entries(), &from_schema/1)]
    end
  end

  @doc "The credential a tie resolves to, and the one every write defaults to."
  @spec primary(keyword()) :: Credential.t() | nil
  def primary(opts \\ []) do
    credentials = credentials(opts)

    Enum.find(credentials, & &1.primary?) || List.first(credentials)
  end

  @doc """
  True when more than one credential is available to spread load across.

  Every hot path checks this first: with one credential there is nothing to
  choose, and the request must take the legacy path untouched.
  """
  @spec pooled?(keyword()) :: boolean()
  def pooled?(opts \\ []), do: length(credentials(opts)) > 1

  @doc "The credential whose current token hashes to `token_key`, or `nil`."
  @spec by_token_key(String.t() | nil, keyword()) :: Credential.t() | nil
  def by_token_key(token_key, opts \\ [])

  def by_token_key(token_key, opts) when is_binary(token_key) and token_key != "" do
    opts |> credentials() |> Enum.find(&(Credential.token_key(&1) == token_key))
  end

  def by_token_key(_token_key, _opts), do: nil

  @doc "The credential with this configured id, or `nil`."
  @spec by_id(String.t(), keyword()) :: Credential.t() | nil
  def by_id(id, opts \\ []) when is_binary(id) do
    opts |> credentials() |> Enum.find(&(&1.id == id))
  end

  @doc """
  The legacy single-credential entry.

  Its `kind` reports what the single-credential path actually authenticates as,
  so a report can distinguish an App installation from a PAT even when no
  `credentials:` list exists.
  """
  @spec legacy_credential() :: Credential.t()
  def legacy_credential do
    %Credential{
      id: @legacy_id,
      kind: if(AppCredentials.configured?(), do: :app_installation, else: :machine_user),
      identity: GitHubConfig.bot_account(),
      source: :legacy,
      writes?: true,
      primary?: true
    }
  end

  defp configured_entries do
    case Config.settings() do
      {:ok, %{tracker: %{github: %{credentials: credentials}}}} when is_list(credentials) ->
        Enum.reject(credentials, &(&1.enabled == false))

      _unavailable ->
        []
    end
  rescue
    _unavailable -> []
  end

  defp from_schema(entry) do
    %Credential{
      id: entry.id,
      kind: kind(entry.kind),
      identity: entry.identity,
      token_env: entry.token_env,
      source: if(entry.kind == "app_installation", do: :app, else: :env),
      writes?: entry.writes == true and entry.kind != "human",
      primary?: false
    }
  end

  defp kind("app_installation"), do: :app_installation
  defp kind("human"), do: :human
  defp kind(_machine_user), do: :machine_user

  defp resolvable?(%Credential{} = credential) do
    case Credential.token(credential) do
      token when is_binary(token) ->
        true

      _unavailable ->
        warn_once(credential)
        false
    end
  end

  # One line per credential per boot, not one per request. The registry is
  # consulted on every GitHub call once pooling is on, and a warning on each
  # would bury the log it is trying to make legible.
  defp warn_once(%Credential{} = credential) do
    key = {__MODULE__, :warned, credential.id}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)
      Logger.warning("github_credential_unavailable id=#{credential.id} source=#{credential.source}")
    end

    :ok
  end
end
