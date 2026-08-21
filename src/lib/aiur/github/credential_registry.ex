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
      _absent -> [legacy_credential(opts) | Enum.map(configured_entries(opts), &from_schema/1)]
    end
  end

  # There is deliberately no `primary/1` here. It existed, had no callers, and
  # returned `Enum.find(&1.primary?) || List.first/1` — an **intent-blind**
  # credential. That is the precise shape of the defect this module's caller
  # shipped with: when the legacy credential does not resolve, no `primary?`
  # entry survives and first place falls to whoever is listed next, which can be
  # a human. Choosing a credential without an intent is not a meaningful
  # question, so the function that made it look meaningful is gone. Ask
  # `Aiur.GitHub.CredentialSelector.choose/3`, which cannot answer without one.

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
  @spec legacy_credential(keyword()) :: Credential.t()
  def legacy_credential(opts \\ []) do
    identity_fun = Keyword.get(opts, :identity_fun, &GitHubConfig.bot_account/0)

    %Credential{
      id: @legacy_id,
      kind: if(AppCredentials.configured?(), do: :app_installation, else: :machine_user),
      # Reporting only — nothing selects on it — so a config read that cannot
      # answer right now yields `nil` rather than taking the request with it.
      identity: safely(identity_fun, nil),
      source: :legacy,
      writes?: true,
      primary?: true
    }
  end

  defp configured_entries(opts) do
    settings_fun = Keyword.get(opts, :settings_fun, &Config.settings/0)

    safely(fn -> credentials_from_config(settings_fun) end, [])
  end

  defp credentials_from_config(settings_fun) do
    case settings_fun.() do
      {:ok, %{tracker: %{github: %{credentials: credentials}}}} when is_list(credentials) ->
        Enum.reject(credentials, &(&1.enabled == false))

      _unavailable ->
        []
    end
  end

  # Both failure modes, deliberately. `Aiur.Config.settings/0` reaches a
  # `GenServer.call` into `Aiur.WorkflowStore`, which throws an **exit** on
  # timeout rather than raising, and `Aiur.GitHub.Config.bot_account/0` goes
  # through `settings!/0`, which **raises** when the config is unavailable. A
  # guard that catches one and not the other reads as safe and is not.
  #
  # This matters more than it looks: the registry is consulted on every GitHub
  # request through `pooled?/1`, so an unguarded config read here would turn a
  # transiently unreadable config into a failed API call rather than into a
  # degraded credential list.
  defp safely(fun, default) do
    fun.()
  rescue
    _unavailable -> default
  catch
    :exit, _reason -> default
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

  # A missing token on the legacy credential is not news from here. It is the
  # ordinary state of a host that has not configured GitHub at all, and
  # `Aiur.GitHub.Config.validate!/0` already reports it precisely at boot. This
  # module exists to explain why a *pooled* credential is absent, so warning
  # about the default one would put a new line on the default path to say
  # something already said better elsewhere.
  defp warn_once(%Credential{source: :legacy}), do: :ok

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
