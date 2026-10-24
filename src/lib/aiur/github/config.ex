defmodule Aiur.GitHub.Config do
  @moduledoc """
  GitHub-specific configuration read from the `github:` YAML section.
  """
  @behaviour Aiur.TrackerConfig
  @impl Aiur.TrackerConfig
  def validate_settings(_settings), do: validate!()
  require Logger
  alias Aiur.GitHub.{AppCredentials, CodeOwners}

  @default_label_prefix "agent"

  @origin_cache_key {__MODULE__, :resolved_origin_repo}

  @doc "The `owner/name` this daemon operates on, from config or the checkout's origin remote."
  @spec repo() :: String.t() | nil
  def repo, do: repo([])

  @spec repo(Aiur.Config.Schema.t()) :: String.t() | nil
  def repo(%Aiur.Config.Schema{} = config), do: explicit_repo(config) || origin_repo([])

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
    configured_repo_from_value(explicit_repo(), opts)
  end

  @doc false
  @spec configured_repo_from_value(term(), keyword()) ::
          {:ok, {String.t(), String.t()}}
          | {:error, :missing_configured_repository | :invalid_configured_repository}
  def configured_repo_from_value(value, opts \\ [])
  def configured_repo_from_value(nil, opts), do: origin_configured_repo(origin_repo(opts))
  def configured_repo_from_value(value, _opts) when is_binary(value), do: parse_configured_repo(value)
  def configured_repo_from_value(_value, _opts), do: {:error, :invalid_configured_repository}

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
  defp explicit_repo(config \\ nil) do
    with value when is_binary(value) <- github_map(config) |> Map.get(:repo),
         trimmed when trimmed != "" <- String.trim(value) do
      trimmed
    else
      _ -> nil
    end
  end

  defp github_map(%Aiur.Config.Schema{} = config), do: Map.from_struct(config.tracker.github)
  defp github_map(_config), do: Aiur.Config.settings!().tracker.github |> Map.from_struct()

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

  @doc false
  @spec resolve_origin_repo((-> String.t() | nil)) :: String.t() | nil
  def resolve_origin_repo(origin_fun \\ &Aiur.Git.origin_repo/0) do
    # `git` ran unlocked: a value cached meanwhile wins over this late result (#4071).
    with value when is_binary(value) <- origin_fun.(),
         :unset <- :persistent_term.get(@origin_cache_key, :unset) do
      # The one operator-facing surface that names which repository an unconfigured
      # install actually resolved to. Without it, a daemon launched from the wrong
      # directory auto-detects that directory's repository and reports nothing.
      Logger.info("aiur_config phase=repo_auto_detected repo=#{value} cwd=#{origin_cwd()} reason=tracker_github_repo_unset")
      :persistent_term.put(@origin_cache_key, value)
      value
    else
      cached_or_nil -> cached_or_nil
    end
  end

  defp origin_cwd do
    case File.cwd() do
      {:ok, cwd} -> cwd
      _error -> "unknown"
    end
  end

  @spec token() :: String.t() | nil
  defdelegate token(), to: Aiur.GitHub.Access.Token

  @spec resolve_token(keyword()) :: String.t() | nil
  defdelegate resolve_token(opts \\ []), to: Aiur.GitHub.Access.Token

  @spec token_source() :: :github_app | :env | :keyring | :none
  defdelegate token_source(), to: Aiur.GitHub.Access.Token

  @spec label_prefix() :: String.t()
  def label_prefix, do: label_prefix(section_value("label_prefix"))

  @doc false
  @spec label_prefix(term()) :: String.t()
  def label_prefix(configured) do
    case configured do
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
  defdelegate app_account(), to: Aiur.GitHub.Access.Token

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
  defdelegate daemon_account(), to: Aiur.GitHub.Access.Token

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
  defdelegate app_identity_issue(), to: Aiur.GitHub.Access.Token

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

  @spec keyring_command_timeout_ms() :: pos_integer()
  defdelegate keyring_command_timeout_ms(), to: Aiur.GitHub.Access.Token

  @spec keyring_timeout_ms(keyword()) :: pos_integer()
  defdelegate keyring_timeout_ms(opts \\ []), to: Aiur.GitHub.Access.Token

  @spec keyring_token(keyword()) :: String.t() | nil
  defdelegate keyring_token(opts \\ []), to: Aiur.GitHub.Access.Token

  @spec kill_os_process(term(), keyword()) :: :ok
  defdelegate kill_os_process(pid, opts \\ []), to: Aiur.GitHub.Access.Token
end
