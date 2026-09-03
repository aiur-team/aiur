defmodule Aiur.GitHub.Config do
  @moduledoc """
  GitHub-specific configuration read from the `github:` YAML section.
  """

  @behaviour Aiur.TrackerConfig

  require Logger

  alias Aiur.GitHub.{AppCredentials, AppToken, AppTokenRefresher, CodeOwners, HostCommand, Transport}

  @default_label_prefix "agent"

  @doc """
  The `owner/name` this daemon operates on.

  `tracker.github.repo` when it carries a value, otherwise the current
  checkout's `origin` remote — the auto-detect path a general global
  `~/.aiur/config` that names no repo of its own relies on.
  """
  @spec repo() :: String.t() | nil
  def repo, do: explicit_repo() || Aiur.Git.origin_repo()

  @doc """
  The repository tracker identities are qualified by, as an `{owner, name}`
  pair.

  Resolves the *same* repository `repo/0` does, including the fallback to the
  current checkout's `origin` remote when `tracker.github.repo` carries no
  value. Every GitHub call already picks its repository through `repo/0`
  (`Aiur.GitHub.Transport.parse_repo/0`), so without the fallback a daemon
  launched against a shared config that names no repo polls its origin
  repository happily while every issue it reads normalizes to an unjoinable
  identity — `:missing_tracker_identity` at pre-spawn, and no agent can
  start (#2518). Sharing one `~/.aiur/config` across repositories only works if
  identity resolves the repository being polled rather than disagreeing
  with it.

  A *present but malformed* `tracker.github.repo` stays fail-closed as
  `:invalid_configured_repository`: a typo must not silently redirect identity
  at whatever checkout the daemon happens to have been launched from.
  """
  @spec configured_repo() ::
          {:ok, {String.t(), String.t()}}
          | {:error, :missing_configured_repository | :invalid_configured_repository}
  def configured_repo, do: configured_repo([])

  @doc """
  `configured_repo/0` with an injectable origin resolver.

  `:origin_fun` defaults to `Aiur.Git.origin_repo/0` and is only consulted when
  `tracker.github.repo` carries no value, so a test can exercise both the
  fallback and the fail-closed path without depending on the checkout it runs
  in.
  """
  @spec configured_repo(keyword()) ::
          {:ok, {String.t(), String.t()}}
          | {:error, :missing_configured_repository | :invalid_configured_repository}
  def configured_repo(opts) when is_list(opts) do
    case explicit_repo() do
      value when is_binary(value) ->
        parse_configured_repo(value)

      nil ->
        opts
        |> Keyword.get(:origin_fun, &Aiur.Git.origin_repo/0)
        |> origin_configured_repo()
    end
  end

  # The configured value with surrounding whitespace removed, or nil when the
  # key is absent, blank, or not a string. Blank is treated exactly like absent
  # so a config reset to its annotated template (`repo:` with nothing after it)
  # takes the same auto-detect path as one that omits the key.
  defp explicit_repo do
    with value when is_binary(value) <- section_value("repo"),
         trimmed when trimmed != "" <- String.trim(value) do
      trimmed
    else
      _ -> nil
    end
  end

  defp origin_configured_repo(origin_fun) when is_function(origin_fun, 0) do
    case origin_fun.() do
      value when is_binary(value) -> parse_configured_repo(value)
      _ -> {:error, :missing_configured_repository}
    end
  end

  @spec token() :: String.t() | nil
  def token do
    if AppCredentials.configured?() do
      AppTokenRefresher.current_token()
    else
      case :persistent_term.get({__MODULE__, :resolved_token}, :unset) do
        :unset -> normalize_secret(System.get_env("GITHUB_TOKEN"))
        resolved -> resolved
      end
    end
  end

  @doc """
  Resolve the GitHub token once at startup.

  When GitHub App credentials are configured (`GITHUB_APP_ID`,
  `GITHUB_APP_INSTALLATION_ID` and the App private key), acquires and caches a
  short-lived installation token synchronously — the App-token analogue of the
  PAT path's boot-time rate-limit probe — so the pollers never start without a
  credential. On failure it logs a warning and returns nil without crashing
  boot; the `Aiur.GitHub.AppTokenRefresher` keeps retrying and raising
  needs-attention alerts.

  Otherwise prefers a VALID `GITHUB_TOKEN` env var, but falls back to the gh
  keyring when the env token is absent or invalid (e.g. a stale token sourced
  from .env). Caches the result; `token/0` returns it.
  """
  @spec resolve_token(keyword()) :: String.t() | nil
  def resolve_token(opts \\ []) do
    if AppCredentials.configured?() do
      resolve_installation_token(opts)
    else
      resolve_pat_token(opts)
    end
  end

  defp resolve_installation_token(opts) do
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    validate_fun = Keyword.get(opts, :validate_fun, &AppToken.rate_limit_usable?/2)
    acquire_fun = Keyword.get(opts, :acquire_fun, &AppToken.acquire/1)

    case acquire_fun.(request_fun: request_fun, validate_fun: validate_fun) do
      {:ok, %{token: token, expires_at: expires_at, permissions: permissions}}
      when is_binary(token) and token != "" ->
        :ok = AppTokenRefresher.cache_token(token, expires_at, permissions)
        token

      {:error, reason} ->
        # Sanitized: the raw reason can carry the private-key file path.
        sanitized = AppCredentials.sanitize_error(reason)
        Logger.warning("aiur_boot phase=github_app_token_resolve_failed reason=#{inspect(sanitized)}")
        nil
    end
  end

  defp resolve_pat_token(opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.get/2)

    validate =
      Keyword.get(opts, :validate_fun, fn token ->
        valid_github_token?(token, request_fun)
      end)

    keyring = Keyword.get(opts, :keyring_fun, &keyring_token/0)
    env = normalize_secret(System.get_env("GITHUB_TOKEN"))

    {resolved, source} =
      cond do
        is_binary(env) and validate.(env) -> {env, :env}
        (kt = keyring.()) && is_binary(kt) && validate.(kt) -> {kt, :keyring}
        true -> {env, if(is_binary(env), do: :env, else: :none)}
      end

    # Only cache a real token; caching nil would shadow a later GITHUB_TOKEN
    # (e.g. per-test env), since token/0 treats a cached nil as resolved.
    if is_binary(resolved) do
      :persistent_term.put({__MODULE__, :resolved_token}, resolved)
      :persistent_term.put({__MODULE__, :resolved_token_source}, source)
    end

    resolved
  end

  @doc """
  The source the currently-resolved GitHub token was obtained from:
  `:github_app` (App installation token), `:env` (`GITHUB_TOKEN`), `:keyring`
  (the `gh` keyring from `gh auth login`), or `:none`.

  The env var is always the source of truth for a token read straight from
  `GITHUB_TOKEN` before `resolve_token/1` runs; once a token has been resolved
  this reports where that resolution actually found a usable credential.
  """
  @spec token_source() :: :github_app | :env | :keyring | :none
  def token_source do
    cond do
      AppCredentials.configured?() ->
        :github_app

      (source = :persistent_term.get({__MODULE__, :resolved_token_source}, nil)) in [:env, :keyring] ->
        source

      nonblank_token?(System.get_env("GITHUB_TOKEN")) ->
        :env

      true ->
        :none
    end
  end

  defp nonblank_token?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank_token?(_value), do: false

  @spec label_prefix() :: String.t()
  def label_prefix do
    case section_value("label_prefix") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> @default_label_prefix
          trimmed -> trimmed
        end

      _ ->
        @default_label_prefix
    end
  end

  @spec planning_root_limit() :: pos_integer()
  def planning_root_limit, do: section_value("planning_root_limit")

  @spec planning_page_budget() :: pos_integer()
  def planning_page_budget, do: section_value("planning_page_budget")

  @spec planning_call_budget() :: pos_integer()
  def planning_call_budget, do: section_value("planning_call_budget")

  @doc """
  The GitHub login **agents** publish as: the account that pushes branches,
  opens pull requests, and comments on behalf of a ticket. Read from
  `tracker.github.bot_account` in .aiur/config.

  Returns `nil` when unset — `validate!/0` does not require it, since
  bot identity is only load-bearing for the events foundation (CODEOWNERS
  allowlist self-include + native dependency authorship).

  This is **not** necessarily the identity the daemon itself writes as; under
  GitHub App auth the daemon writes as the App bot. Ask `daemon_account/0` for
  that one. A call site that means "the account this daemon posts under" and
  reads `bot_account/0` will silently misbehave on a split-identity install.
  """
  @spec bot_account() :: String.t() | nil
  def bot_account, do: normalize_account(section_value("bot_account"))

  @doc """
  Which identity arrangement this install runs: `:separate_account` (agents
  post as a login no human uses) or `:single_account` (the operator's own login
  is also the agents').

  Read from `tracker.github.identity_mode`, which the schema constrains to those
  two spellings. Anything else — an unloaded config, a hand-edited typo that
  bypassed validation — resolves to `:separate_account`, because that mode
  answers authorship from the author login and so cannot mistake an operator's
  comment for an agent's.
  """
  @spec identity_mode() :: :separate_account | :single_account
  def identity_mode do
    case section_value("identity_mode") do
      "single_account" -> :single_account
      :single_account -> :single_account
      _otherwise -> :separate_account
    end
  end

  @doc """
  Whether agents and the human operator share one GitHub login.
  """
  @spec single_account?() :: boolean()
  def single_account?, do: identity_mode() == :single_account

  @doc """
  The GitHub App bot login the daemon writes as, from
  `tracker.github.github_app.account`, or `nil` when no App identity is
  configured.

  Optional by construction: an install with no `github_app` block keeps a
  single identity and every daemon-side consumer falls back to `bot_account/0`.
  """
  @spec app_account() :: String.t() | nil
  def app_account do
    case section_value("github_app") do
      %{account: account} -> normalize_account(account)
      _absent -> nil
    end
  end

  @doc """
  The login the **daemon** writes as: the App bot when one is configured,
  otherwise the bot account.

  Use this for anything keyed on "did this daemon produce this event" —
  self-loop suppression, the PR command scanner's own-comment drop, credential
  identity reporting. Use `bot_account/0` for anything keyed on "did an agent
  author this".

  The fallback is deliberately to `bot_account/0` and stops there. It must
  never widen into a chain that can reach an ambient `gh` keyring identity: the
  keyring on an operator's machine is the human, whose authorship the merge
  policy treats as disqualifying, so failing open to it is worse than resolving
  nothing.
  """
  @spec daemon_account() :: String.t() | nil
  def daemon_account, do: app_account() || bot_account()

  defp normalize_account(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_account(_value), do: nil

  @doc """
  Checks that the daemon's configured identity names what it actually writes
  as.

  A GitHub App installation token authenticates as the App's bot user
  (`<app-slug>[bot]`), never as the operator account a PAT authenticated as.
  Every identity-keyed gate — `Events.Publisher`'s self-loop suppression, the
  PR command scanner's self-loop drop, review-thread reply verification, the
  CODEOWNERS self-include — compares the event actor against `daemon_account/0`,
  so a daemon identity left pointing at the old PAT account silently stops
  recognizing the daemon's own writes and the daemon reacts to itself.

  Resolution goes through `daemon_account/0`, so an install that predates
  `tracker.github.github_app` and set `bot_account` to the App bot is still
  correct and still silent.

  Returns `nil` when the daemon is on the PAT path or the resolved daemon
  identity already names an App bot; otherwise the concrete misconfiguration.
  """
  @spec app_identity_issue() :: nil | :bot_account_missing | {:bot_account_not_app_bot, String.t()}
  def app_identity_issue do
    if AppCredentials.configured?(), do: bot_account_issue(daemon_account())
  end

  defp bot_account_issue(nil), do: :bot_account_missing

  # Case-insensitive, matching every consumer of bot_account: an operator who
  # wrote `My-App[Bot]` has a working config and must not be alerted.
  defp bot_account_issue(login) do
    unless String.ends_with?(String.downcase(login), "[bot]"), do: {:bot_account_not_app_bot, login}
  end

  @doc """
  Returns additional GitHub logins whose comments are trusted for agent
  delivery without treating them as Aiur self-loop authors.
  """
  @spec trusted_accounts() :: [String.t()]
  def trusted_accounts do
    case section_value("trusted_accounts") do
      accounts when is_list(accounts) ->
        accounts
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq_by(&String.downcase/1)

      account when is_binary(account) ->
        case String.trim(account) do
          "" -> []
          trimmed -> [trimmed]
        end

      _ ->
        []
    end
  end

  @doc """
  Returns the explicit dispatch allowlist, or the running CODEOWNERS-derived
  allowlist when it is absent. An unavailable or empty fallback denies all
  dispatches rather than opening the trust boundary.
  """
  @spec allowed_users() :: [String.t()]
  def allowed_users do
    case normalize_logins(section_value("allowed_users")) do
      [] -> codeowners_users()
      users -> users
    end
  end

  @doc """
  Returns the explicit human-only merge allowlist. Unlike comment trust and
  dispatch authorization, this list never inherits CODEOWNERS, bot accounts,
  or other trusted identities. An absent list denies all mergers.
  """
  @spec human_mergers() :: [String.t()]
  def human_mergers do
    section_value("human_mergers")
    |> normalize_logins()
  end

  @doc """
  Returns true only when `login` is explicitly configured as a human merger.
  Login matching is case-insensitive.
  """
  @spec human_merger_allowed?(String.t() | nil, [String.t()]) :: boolean()
  def human_merger_allowed?(login, allowed \\ human_mergers())

  def human_merger_allowed?(nil, _allowed), do: false

  def human_merger_allowed?(login, allowed) when is_binary(login) and is_list(allowed) do
    normalized_login = login |> String.trim() |> String.downcase()

    Enum.any?(allowed, fn candidate ->
      is_binary(candidate) and String.downcase(String.trim(candidate)) == normalized_login
    end)
  end

  @doc """
  Whether opt-in repo-wide PR comment watching is enabled (`pr_watch.enabled`).
  When false, aiur only reacts to comments on its own `aiur/<id>` PRs.
  """
  @spec pr_watch_enabled?() :: boolean()
  def pr_watch_enabled? do
    Aiur.Config.settings!().pr_watch.enabled
  end

  @doc """
  The fully-qualified opt-in watch label (e.g. `agent:watch`), combining the
  github `label_prefix/0` with `pr_watch.watch_label`.
  """
  @spec watch_label() :: String.t()
  def watch_label do
    "#{label_prefix()}:#{Aiur.Config.settings!().pr_watch.watch_label}"
  end

  @doc """
  The one-off per-comment command prefix (e.g. `/aiur`). A trusted comment
  starting with this — or mentioning `daemon_account/0` — wakes an agent for that
  single comment, no label required.
  """
  @spec command_prefix() :: String.t()
  def command_prefix do
    Aiur.Config.settings!().pr_watch.command_prefix
  end

  @doc """
  Whether the PR-health scanner runs (`pr_health.enabled`). Opt-in so a repo
  that has not configured thresholds pays no GitHub API budget.
  """
  @spec pr_health_enabled?() :: boolean()
  def pr_health_enabled? do
    Aiur.Config.settings!().pr_health.enabled
  end

  @doc "PR-health scan cadence, in milliseconds."
  @spec pr_health_interval_ms() :: pos_integer()
  def pr_health_interval_ms do
    interval = Aiur.Config.settings!().pr_health.interval_seconds
    max(interval, 1) * 1_000
  end

  @doc "A non-draft PR older than this many hours with no review is flagged."
  @spec pr_health_stale_hours() :: pos_integer()
  def pr_health_stale_hours do
    Aiur.Config.settings!().pr_health.stale_hours
  end

  @impl Aiur.TrackerConfig
  def validate! do
    cond do
      AppCredentials.configured?() and !is_binary(token()) ->
        {:error, "GitHub App installation token unavailable — check GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and the App private key"}

      !AppCredentials.configured?() and !is_binary(token()) ->
        {:error, "GitHub token missing — set GITHUB_TOKEN env var"}

      !is_binary(repo()) ->
        {:error, "GitHub repo missing — set github.repo in .aiur/config"}

      true ->
        :ok
    end
  end

  defp section_value(key) do
    Aiur.Config.settings!().tracker.github
    |> Map.from_struct()
    |> Map.get(String.to_existing_atom(key))
  end

  defp normalize_logins(accounts) when is_list(accounts) do
    accounts
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp normalize_logins(account) when is_binary(account), do: normalize_logins([account])
  defp normalize_logins(_accounts), do: []

  defp codeowners_users do
    if Process.whereis(CodeOwners) do
      CodeOwners.codeowners_snapshot()
    else
      []
    end
  catch
    :exit, _reason -> []
  end

  defp parse_configured_repo(value) do
    case String.split(String.trim(value), "/") do
      [owner, repo] when owner != "" and repo != "" -> {:ok, {owner, repo}}
      _ -> {:error, :invalid_configured_repository}
    end
  end

  @doc """
  Query the gh keyring with the env tokens CLEARED so gh returns the stored
  login rather than echoing the (possibly stale) env var.

  Returns the stored PAT as a trimmed string, or `nil` when gh is absent, not
  logged in via keyring (headless/CI), or the lookup fails.

  Routed through the host guard so the keyring lookup is admitted and recorded
  like every other gh call (#2353). This is the single source of truth for
  "does a gh keyring credential exist": `resolve_pat_token/1` uses it as its
  runtime fallback, and the boot gate in `Aiur.Env` consults the same function
  so a keyring-only `gh auth login` satisfies the GitHub credential requirement
  before any env token is set.
  """
  @spec keyring_token() :: String.t() | nil
  def keyring_token do
    case HostCommand.run(["auth", "token", "--hostname", "github.com"],
           env: [{"GITHUB_TOKEN", ""}, {"GH_TOKEN", ""}],
           stderr_to_stdout: true
         ) do
      {out, 0} -> normalize_secret(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Cheap validity probe: GET /rate_limit returns 200 for a syntactically usable
  # token, but an exhausted core quota still wedges the fleet (#617). Treat a
  # 200 response with remaining=0 as unusable so boot can fall back from a stale
  # `.env` token to `gh` keyring auth when available.
  defp valid_github_token?(token, request_fun)
       when is_binary(token) and is_function(request_fun, 2) do
    case request_fun.("https://api.github.com/rate_limit",
           headers: [
             {"Authorization", "Bearer #{token}"},
             {"Accept", "application/vnd.github+json"},
             {"User-Agent", "aiur"}
           ],
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        rate_limit_usable?(response)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp valid_github_token?(_, _), do: false

  defp rate_limit_usable?(response) do
    case rate_limit_remaining(response) do
      0 -> false
      _remaining -> true
    end
  end

  defp rate_limit_remaining(%{headers: headers} = response) do
    header_remaining(headers) || body_remaining(response)
  end

  defp rate_limit_remaining(%{} = response), do: body_remaining(response)

  defp header_remaining(headers) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {key, value} ->
        if String.downcase(to_string(key)) == "x-ratelimit-remaining" do
          parse_integer(value)
        end

      _ ->
        nil
    end)
  end

  defp header_remaining(headers) when is_map(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == "x-ratelimit-remaining" do
        parse_integer(value)
      end
    end)
  end

  defp header_remaining(_headers), do: nil

  defp body_remaining(%{body: %{"resources" => %{"core" => %{"remaining" => remaining}}}}),
    do: parse_integer(remaining)

  defp body_remaining(%{body: %{"rate" => %{"remaining" => remaining}}}),
    do: parse_integer(remaining)

  defp body_remaining(_response), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer([value | _]), do: parse_integer(value)

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp normalize_secret(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret(_value), do: nil
end
