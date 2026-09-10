defmodule Aiur.GitHub.Config do
  @moduledoc """
  GitHub-specific configuration read from the `github:` YAML section.
  """

  @behaviour Aiur.TrackerConfig

  require Logger

  alias Aiur.GitHub.{AppCredentials, AppToken, AppTokenRefresher, CodeOwners, HostCommand, Transport}

  @default_label_prefix "agent"

  @origin_cache_key {__MODULE__, :resolved_origin_repo}

  @doc """
  The `owner/name` this daemon operates on.

  `tracker.github.repo` when it carries a value, otherwise the current
  checkout's `origin` remote — the auto-detect path a general global
  `~/.aiur/config` that names no repo of its own relies on.
  """
  @spec repo() :: String.t() | nil
  def repo, do: repo([])

  @doc """
  `repo/0` with the same injectable `:origin_fun` seam `configured_repo/1` takes.
  """
  @spec repo(keyword()) :: String.t() | nil
  def repo(opts) when is_list(opts), do: explicit_repo() || origin_repo(opts)

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
      value when is_binary(value) -> parse_configured_repo(value)
      nil -> origin_configured_repo(origin_repo(opts))
    end
  end

  @doc """
  Only the repository `tracker.github.repo` names explicitly, never the
  checkout's `origin` remote.

  This is the reader for durable, on-disk scoping that must not move when a
  repository is auto-detected rather than configured. `Aiur.IssueLog` derives
  every transcript filename and its writer registry key from this scope, so
  resolving it through `configured_repo/0`'s fallback would rename every log
  file on the first restart after an upgrade and orphan the existing history.
  Identity resolution wants the fallback; durable paths do not.
  """
  @spec explicit_configured_repo() ::
          {:ok, {String.t(), String.t()}}
          | {:error, :missing_configured_repository | :invalid_configured_repository}
  def explicit_configured_repo do
    case explicit_repo() do
      value when is_binary(value) -> parse_configured_repo(value)
      nil -> {:error, :missing_configured_repository}
    end
  end

  @doc """
  A one-line account of where the tracker repository was looked for and what
  was found: the config file actually read, every path searched to choose it,
  the working directory, the `tracker.github.repo` value, and the detected
  `origin` remote.

  `:missing_tracker_identity` on its own points a reader at the wrong file. In
  #2518 an operator was twice told their configuration had been "reverted to
  the template" and advised to restore it; the configuration was fine. The
  failing daemon was reading the global `~/.aiur/config` while the operator was
  reading a repo-local `.aiur/config` — two genuinely different files, one of
  which legitimately carries no `tracker.github` block. That cost two
  investigations and a recommendation to edit a live config for no reason. Any
  error reporting unresolvable tracker identity has to name the file it read
  and the paths it searched, or it sends the next reader down the same path.
  """
  @spec repository_resolution_diagnostic() :: String.t()
  def repository_resolution_diagnostic do
    Enum.join(
      [
        "config_read=#{Aiur.Workflow.workflow_file_path()}",
        "searched=#{Enum.join(Aiur.Workflow.config_path_candidates(), ",")}",
        "cwd=#{origin_cwd()}",
        "tracker.github.repo=#{explicit_repo() || "unset"}",
        "origin=#{origin_repo([]) || "none"}"
      ],
      " "
    )
  rescue
    # A diagnostic must never be the reason a failure path fails.
    error -> "config_read=unavailable diagnostic_error=#{inspect(error.__struct__)}"
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

  defp origin_configured_repo(value) when is_binary(value), do: parse_configured_repo(value)
  defp origin_configured_repo(_value), do: {:error, :missing_configured_repository}

  # Resolved once per VM rather than per call. `Aiur.Git.origin_repo/0` shells
  # out to git, and `configured_repo/0` runs once per issue during poll
  # normalization, so an uncached fallback would fork a process per issue on
  # exactly the shared-config installs it exists to serve. More importantly it
  # would leave `repo/0` and `configured_repo/0` reading two independent `git`
  # invocations at different instants: a transient failure of one alone yields
  # `:repository_mismatch` or `:missing_configured_repository`, turning the
  # deterministic #2518 bug into an intermittent one. Caching makes the two
  # agree by construction. Only a binary is cached, so a transient failure is
  # retried on the next call instead of frozen in for the process lifetime.
  defp origin_repo(opts) do
    case Keyword.get(opts, :origin_fun) do
      origin_fun when is_function(origin_fun, 0) ->
        origin_fun.()

      _default ->
        case :persistent_term.get(@origin_cache_key, :unset) do
          :unset -> resolve_origin_repo()
          resolved -> resolved
        end
    end
  end

  defp resolve_origin_repo do
    case Aiur.Git.origin_repo() do
      value when is_binary(value) ->
        # The one operator-facing surface that names which repository an
        # unconfigured install actually resolved to. Without it, a daemon
        # launched from the wrong directory auto-detects that directory's
        # repository and reports nothing.
        Logger.info("aiur_config phase=repo_auto_detected repo=#{value} cwd=#{origin_cwd()} reason=tracker_github_repo_unset")

        :persistent_term.put(@origin_cache_key, value)
        value

      _other ->
        nil
    end
  end

  defp origin_cwd do
    case File.cwd() do
      {:ok, cwd} -> cwd
      _error -> "unknown"
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

  # Bound on the `gh auth token` keyring shell-out (#2393). A gh that prompts on
  # a locked keyring, blocks on a slow/unreachable host, or waits on a missing
  # GUI credential agent would otherwise hang boot before any log line on the
  # keyring-only path a new developer takes. 5s matches the webhook admission
  # deadline idiom and is far longer than a healthy local keyring lookup; the
  # default is overridable through `AIUR_GH_KEYRING_TIMEOUT_MS` for a
  # slow-but-succeeding setup (see `keyring_timeout_ms/1`).
  @keyring_command_timeout_ms 5_000
  @keyring_timeout_env "AIUR_GH_KEYRING_TIMEOUT_MS"
  @keyring_os_pid_key :aiur_gh_keyring_os_pid

  @doc """
  The default timeout (milliseconds) for the `gh auth token` keyring shell-out,
  applied when `#{@keyring_timeout_env}` is unset.

  Exposed so the boot-safety bound is testable: a boot stall from a locked
  keyring must stay well under the ten-minute mark, and a mutation of the
  private `@keyring_command_timeout_ms` would otherwise ship silently because
  every test injects its own `timeout_ms`.
  """
  @spec keyring_command_timeout_ms() :: pos_integer()
  def keyring_command_timeout_ms, do: @keyring_command_timeout_ms

  @doc """
  The effective keyring lookup timeout in milliseconds.

  `:timeout_ms` in `opts` wins, then `#{@keyring_timeout_env}` when it is a
  positive integer, then the compiled-in `keyring_command_timeout_ms/0`
  default. The env override exists so a slow-but-succeeding keyring (e.g. an
  interactive unlock prompt that legitimately takes longer than the 5s default)
  is not converted into a spurious "no keyring credential" at boot; an invalid
  env value is ignored rather than crashing boot.
  """
  @spec keyring_timeout_ms(keyword()) :: pos_integer()
  def keyring_timeout_ms(opts \\ []) do
    Keyword.get(opts, :timeout_ms, env_keyring_timeout_ms() || @keyring_command_timeout_ms)
  end

  defp env_keyring_timeout_ms do
    case System.get_env(@keyring_timeout_env) do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {ms, ""} when ms > 0 -> ms
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Query the gh keyring with the env tokens CLEARED so gh returns the stored
  login rather than echoing the (possibly stale) env var.

  Returns the stored PAT as a trimmed string, or `nil` when gh is absent, not
  logged in via keyring (headless/CI), the lookup fails, or the shell-out does
  not answer within `keyring_timeout_ms/1`. A timeout is treated exactly like
  an absent gh — "no keyring credential" — never a fatal error, and it is
  logged at warning level so a stalled keyring is attributable instead of a
  silent boot hang.

  Logs at debug level immediately before the shell-out, so even a boot that
  hangs (within the timeout) leaves a line to read rather than stopping with no
  output.

  Routed through the host guard so the keyring lookup is admitted and recorded
  like every other gh call (#2353). This is the single source of truth for
  "does a gh keyring credential exist": `resolve_pat_token/1` uses it as its
  runtime fallback, and the boot gate in `Aiur.Env` consults the same function
  so a keyring-only `gh auth login` satisfies the GitHub credential requirement
  before any env token is set.

  ## Options

    * `:timeout_ms` — bound on the shell-out, overriding the
      `#{@keyring_timeout_env}` default (test seam).
    * `:run_fun` — how the `gh auth token` command runs, defaulting to the
      `HostCommand`-routed port spawn. Test seam so the in-task rescue that
      turns a raising runner into "no keyring credential" is load-bearing.
    * `:wrapper_dir` — the guard-wrapper directory `HostCommand.find_executable/1`
      prefers, as in that function. Test seam that selects the process TOPOLOGY
      of the shell-out, which the timeout kill has to survive either way: with a
      wrapper installed the port child is the wrapper and the real `gh` is a
      GRANDchild (a dev box), while with no wrapper the `gh` on PATH is the
      DIRECT child (CI). Pointing this at an empty directory reproduces the CI
      topology deliberately instead of only in CI — which is where the
      direct-pid kill regressed.
  """
  @spec keyring_token(keyword()) :: String.t() | nil
  def keyring_token(opts \\ []) do
    timeout_ms = keyring_timeout_ms(opts)
    wrapper_dir = Keyword.get(opts, :wrapper_dir)
    run_fun = Keyword.get(opts, :run_fun, fn -> run_gh_auth_token_command(wrapper_dir) end)

    Logger.debug(
      "aiur_boot phase=github_keyring_lookup state=starting " <>
        "command=\"gh auth token --hostname github.com\" timeout_ms=#{timeout_ms}"
    )

    case run_bounded_gh_auth_token(timeout_ms, run_fun) do
      {out, 0} -> normalize_secret(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Runs `run_fun` in a linked task so the caller can bound it. A command that
  # never returns is torn down after `timeout_ms` and the whole lookup degrades
  # to "no keyring credential" — nil — the same way an absent gh is treated,
  # never a fatal error.
  #
  # The guard must live INSIDE the task: Task.async links the task to the
  # caller, so an uncaught exception inside the task would exit it abnormally
  # and the link would kill the caller before Task.yield ever returned —
  # crashing boot on the exact new-developer box this protects. The `:run_fun`
  # seam makes that guard load-bearing: a test injects a runner that raises
  # and asserts the caller survives with nil. `catch _, _ -> nil` is included
  # because `rescue` only covers raises: a `throw` or `exit` from `run_fun`
  # would otherwise exit the linked task by the same path.
  #
  # The timeout path also kills the port child and everything it spawned.
  # Closing the task's port sends EOF but never signals the OS process, so a
  # stalled `gh` that outlived the port would keep holding the locked keyring /
  # credential-helper prompt and every later lookup would spawn another orphan.
  # The child's OS pid is published to the task's dictionary by the runner and
  # read here while the task is still alive; `kill_os_process/1` then signals
  # the direct pid, its descendants and the group it may lead (see its comment
  # for why the group alone cannot be relied on). The kill runs BEFORE the task
  # is torn down: Task.shutdown closes the port, erl_child_setup may reap the
  # child, and the OS could recycle the pid before a later kill landed on an
  # unrelated process.
  defp run_bounded_gh_auth_token(timeout_ms, run_fun) do
    task =
      Task.async(fn ->
        try do
          run_fun.()
        rescue
          _ -> nil
        catch
          _, _ -> nil
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        # With the in-task guard the task never exits abnormally; kept as a
        # defensive fallback so an unexpected exit still degrades to "no
        # keyring credential" rather than a crash.
        nil

      nil ->
        os_pid = task_keyring_os_pid(task)
        kill_os_process(os_pid)
        Task.shutdown(task, :brutal_kill)

        Logger.warning(
          "aiur_boot phase=github_keyring_lookup state=timed_out " <>
            "timeout_ms=#{timeout_ms} treated_as=no_keyring_credential " <>
            "run `gh auth login` to use the gh keyring"
        )

        nil
    end
  end

  # The real runner: `gh auth token --hostname github.com` with the env tokens
  # cleared so gh returns the stored keyring login rather than echoing a
  # (possibly stale) env var. The executable is resolved through
  # HostCommand.find_executable/1 so the guard wrapper is used when installed
  # (budget admission, #2353). The command runs as a port so the bounded runner
  # can read the child's OS pid from the task dictionary and kill it and its
  # descendants on timeout — reaching a guard wrapper AND the `gh` /
  # lease-renewer it spawned, not just the direct child. Closing the port
  # alone would orphan the process.
  defp run_gh_auth_token_command(wrapper_dir) do
    case HostCommand.find_executable(wrapper_dir: wrapper_dir) do
      nil ->
        {"", 127}

      path ->
        port =
          Port.open({:spawn_executable, String.to_charlist(path)}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:args, ["auth", "token", "--hostname", "github.com"]},
            {:env, [{~c"GITHUB_TOKEN", ~c""}, {~c"GH_TOKEN", ~c""}]}
          ])

        Process.put(@keyring_os_pid_key, port_os_pid(port))
        collect_port_output(port)
    end
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _ -> nil
    end
  end

  defp task_keyring_os_pid(task) do
    case Process.info(task.pid, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, @keyring_os_pid_key) do
          pid when is_integer(pid) and pid > 0 -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Kills the port child and everything it spawned, BY PID ONLY. Never a
  # process group.
  #
  # A process group is not a safe unit to signal from inside a CI job. On a
  # GitHub-hosted runner the whole job shares one group — measured on the
  # runner that failed #2560:
  #
  #     PID   PGID   PPID    SID  COMMAND
  #    2108   2034   2034   2034  Runner.Listener
  #    2128   2034   2108   2034  Runner.Worker
  #    2428   2034    ...   2034  the step shell (-> timeout -> make -> beam.smp)
  #
  # so a `kill -<sig> -<pgid>` that lands on that group SIGTERMs the Actions
  # runner itself. That is what #2560 looked like from outside: the job died
  # mid-step with exit 143 and "the runner has received a shutdown signal", no
  # test output at all, and no remaining step ran — including the one that
  # would have printed the partition log. An instrumented run put 8 ms between
  # this function's group signal and the runner's death.
  #
  # The group signal was never load-bearing: the descendant walk below already
  # reaches the guard wrapper, the real `gh` it spawned and any background
  # lease renewer, because it enumerates them from the live process table.
  # Signalling a group only added a way to hit processes this code never
  # spawned. Every target here is now a pid that walk actually found.
  #
  # TERM is sent first — to the root and to every descendant already
  # enumerated — so a wrapper's cleanup trap can release the budget lease
  # (SIGKILL is untrappable), then, after a brief bound for that trap to run,
  # KILL clears anything that ignored TERM. The kill runs BEFORE the task is
  # torn down: Task.shutdown closes the port, erl_child_setup may reap the
  # child, and the OS could recycle the pid before a later kill landed on an
  # unrelated process.
  #
  # NO STEP MAY SWALLOW ANOTHER. The kill used to compute
  # `[pid | descendant_os_pids(pid)]` before signalling anything, and the walk
  # parsed pgrep's (stderr-merged) output with `String.to_integer/1`. A single
  # non-numeric byte on that stream raised, the function-level `rescue _ -> :ok`
  # swallowed it, and NO signal was sent at all — silently reintroducing the
  # orphan accumulation this exists to prevent. The walk is now defensive at
  # both levels: `child_os_pids/2` parses with `Integer.parse/1` and drops
  # non-pids, and `safe_descendant_os_pids/2` degrades any walk failure to []
  # rather than aborting the kill, so the direct-pid signals always land.
  #
  # The walk still runs BEFORE the TERM, and that ordering is load-bearing in
  # the other direction: TERM kills the direct child immediately, its children
  # are reparented to init, and `pgrep -P <pid>` then finds nothing. CI proved
  # this — with the walk moved after the TERM the direct `gh` died and its
  # `sleep` grandchild was orphaned. The tree is walked again after the TERM
  # settles and the two results are unioned, so a process that only appears
  # later is still reached.
  #
  # Seams (tests only): `:signal_fun` observes the signals, `:pgrep_fun`
  # supplies the raw child-enumeration output.
  @doc false
  @spec kill_os_process(term(), keyword()) :: :ok
  def kill_os_process(pid, opts \\ [])

  def kill_os_process(pid, opts) when is_integer(pid) and pid > 0 do
    signal = Keyword.get(opts, :signal_fun, &signal_os_pid/2)

    # Enumerated BEFORE the TERM: once the root dies its children reparent to
    # init and `pgrep -P <root>` finds nothing.
    before_term = safe_descendant_os_pids(pid, opts)

    signal.("TERM", pid)
    Enum.each(before_term, &signal.("TERM", &1))

    Process.sleep(150)

    descendants = Enum.uniq(before_term ++ safe_descendant_os_pids(pid, opts))

    signal.("KILL", pid)
    Enum.each(descendants, &signal.("KILL", &1))
    :ok
  rescue
    _ -> :ok
  end

  def kill_os_process(_pid, _opts), do: :ok

  # The descendant walk can never abort the kill: any failure degrades to "no
  # descendants found" and the direct-pid signals still land.
  defp safe_descendant_os_pids(pid, opts) do
    descendant_os_pids(pid, opts)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Sends `signal` to `target`: a positive target is a pid, a negative target
  # (-pid) is the process group led by `pid`. Stderr is captured (and
  # discarded) so an ESRCH on a host where the child does not lead a group
  # cannot raise.
  # A missing `kill` binary raises `:enoent`, which would abort the whole kill
  # sequence; fall back to the shell builtin, and never let one failed signal
  # stop the remaining ones.
  defp signal_os_pid(signal, target) do
    System.cmd("kill", ["-" <> signal, Integer.to_string(target)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> shell_signal_os_pid(signal, target)
  end

  defp shell_signal_os_pid(signal, target) do
    System.cmd("sh", ["-c", "kill -#{signal} #{target} 2>/dev/null"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  # Every descendant OS pid of `pid`, recursively, enumerated from the live
  # process table via pgrep's parent filter (available on Linux and macOS).
  # Returns [] when pgrep is unavailable or the pid has no children.
  defp descendant_os_pids(pid, opts) do
    pid
    |> child_os_pids(opts)
    |> Enum.flat_map(&[&1 | descendant_os_pids(&1, opts)])
  end

  # pgrep's output is captured with `stderr_to_stdout: true`, so the stream can
  # carry a warning line as well as pids. Parse every line defensively and drop
  # what is not a pid: `String.to_integer/1` raised on the first such byte and
  # took the entire kill down with it.
  defp child_os_pids(pid, opts) do
    pgrep = Keyword.get(opts, :pgrep_fun, &run_pgrep/1)

    case pgrep.(pid) do
      {out, 0} -> parse_pids(out)
      _ -> []
    end
  end

  defp run_pgrep(pid) do
    System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true)
  end

  defp parse_pids(out) when is_binary(out) do
    out
    |> String.split()
    |> Enum.flat_map(fn token ->
      case Integer.parse(token) do
        {pid, ""} when pid > 0 -> [pid]
        _ -> []
      end
    end)
  end

  defp parse_pids(_out), do: []

  defp collect_port_output(port, acc \\ "") do
    receive do
      {^port, {:data, data}} -> collect_port_output(port, acc <> data)
      {^port, {:exit_status, status}} -> {acc, status}
    end
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
