defmodule Aiur.Config.Schema.Github do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.Schema.AllowedContributorsParser
  alias Aiur.Config.Schema.GithubApp
  alias Aiur.Config.Schema.GithubCredential

  @max_planning_root_limit 100
  @max_planning_page_budget 4
  @max_planning_call_budget 4
  @default_max_inflight 4
  @default_max_inflight_per_endpoint 2
  @default_requests_per_minute 300
  @default_stagger_ms 75
  @default_daemon_core_limit_per_hour 3000
  @default_daemon_graphql_limit_per_hour 4500
  @default_daemon_search_limit_per_hour 600
  @default_agent_core_limit_per_hour 250
  @default_agent_graphql_limit_per_hour 600
  @default_agent_search_limit_per_hour 600

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-01 tracker.github.repo
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.repo | string | the checkout's `origin` remote | GitHub owner/name used by Aiur. Omitted or left blank, it auto-detects from the `origin` remote of the directory the daemon was launched from — both for the repository Aiur polls and for the repository tracker identities are qualified by, which is what lets several daemons for different repositories share one `~/.aiur/config`. A value that is present but not `owner/name` is rejected rather than auto-detected, so a typo cannot silently redirect a fleet at whatever checkout it happens to run from. Set it explicitly whenever the daemon should track a repository other than its own checkout. |
    field(:repo, :string)
    # @config-reference config-configuration-01 tracker.github.label_prefix
    # @config-detail tracker.github.label_prefix | string | `agent` | Prefixes lifecycle labels. |
    field(:label_prefix, :string, default: "agent")
    # The login **agents** publish as: the account that pushes branches and
    # opens pull requests. Separate from the daemon's App identity below — see
    # `Aiur.Config.Schema.GithubApp`.
    # @config-reference config-configuration-01 tracker.github.bot_account
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.bot_account | string | nil | Login the **agents** publish as — the account that pushes branches, opens pull requests, and comments for a ticket. This is an identity, not the credential: the credential is `GITHUB_TOKEN`. During fresh setup, `aiur init` asks whether agents use your own account or a separate bot account; it derives the former without asking for the login again and asks for the latter once. If the known posting credential names a different account, setup keeps that separate identity rather than recording an untrue shared account. In a non-interactive or `--force` run, valid resolved defaults are used and invalid ones are omitted rather than retried. Re-running `aiur init` preserves an existing value. When no `tracker.github.github_app.account` is set this login also stands in as the daemon's own identity for self-loop suppression. |
    field(:bot_account, :string)
    # Which identity arrangement this install runs, stated rather than guessed.
    #
    #   * `"separate_account"` (default) — agents post as a login no human uses,
    #     so the author login alone answers "did Aiur write this".
    #   * `"single_account"` — the operator's own login is also the agents'
    #     login. Authorship can no longer be read from the author, so it is read
    #     from `Aiur.GitHub.AgentMarker`'s in-body marker instead.
    #
    # Deliberately not inferred from whether `bot_account` equals the token's
    # viewer login: that comparison is true for an operator who has a dedicated
    # bot and happens to run the daemon under it, and false for a single-account
    # operator whose token is a PAT of a machine user. Guessing wrong in either
    # direction silently changes which comments wake an agent.
    # @config-reference config-configuration-01 tracker.github.identity_mode
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.identity_mode | string | `separate_account` | Whether the agents post as a login no human uses (`separate_account`) or share the operator's own login (`single_account`). Stated, never inferred: nothing compares `bot_account` against the token's viewer login to guess, because that guess is wrong in both directions and silently changes which comments wake an agent. Under `separate_account` the author login proves authorship and nothing else is needed. Under `single_account` it proves nothing, so Aiur appends an invisible HTML-comment marker to comments it writes and suppresses only comments carrying it — anything unmarked, including every comment posted before this existed, reads as human and wakes the agent. Any other value is rejected at config load. |
    field(:identity_mode, :string, default: "separate_account")
    # @config-reference config-configuration-01 tracker.github.trusted_accounts
    # @config-detail tracker.github.trusted_accounts | array | `[]` | Usernames allowed to direct agents. |
    field(:trusted_accounts, {:array, :string}, default: [])
    # @config-reference config-configuration-01 tracker.github.allowed_users
    # @config-detail tracker.github.allowed_users | array | `[]` | GitHub logins allowed to use trusted operator paths. |
    field(:allowed_users, {:array, :string}, default: [])
    # @config-reference config-configuration-01 tracker.github.allowed_contributors
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.allowed_contributors | map | nil | Whole intake allow-list: `users: [42]`, `orgs: [{id: 77, login: acme}]`. Positive numeric int64 ids; logins address the membership API only. Present empty map/null admits nobody; present key skips `.github/ALLOWED-CONTRIBUTORS`. Invalid entries fail startup validation. Reload/restart applies changes and alerts with added/removed entries. |
    field(:allowed_contributors, :map)
    # @config-reference config-configuration-01 tracker.github.human_mergers
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.human_mergers | array | `[]` | Explicit human-only allowlist for post-merge attribution, current-head CHANGES_REQUESTED review routing and the planned `aiur pr merge` command. Reviews from these logins can route tickets to rework independently of `trusted_accounts`. Never inherits CODEOWNERS, bot accounts or dispatch users. |
    field(:human_mergers, {:array, :string}, default: [])
    # @config-reference config-configuration-01 tracker.github.planning_root_limit
    # @config-detail tracker.github.planning_root_limit | integer | 100 | Maximum Build Order planning roots fetched in one cycle. |
    field(:planning_root_limit, :integer, default: @max_planning_root_limit)
    # @config-reference config-configuration-01 tracker.github.planning_page_budget
    # @config-detail tracker.github.planning_page_budget | integer | 4 | Maximum GitHub planning pages fetched in one cycle. |
    field(:planning_page_budget, :integer, default: @max_planning_page_budget)
    # @config-reference config-configuration-01 tracker.github.planning_call_budget
    # @config-detail tracker.github.planning_call_budget | integer | 4 | Maximum GitHub planning calls fetched in one cycle. |
    field(:planning_call_budget, :integer, default: @max_planning_call_budget)
    # @config-reference config-configuration-01 tracker.github.max_inflight
    # @config-detail tracker.github.max_inflight | integer | 4 | Cap on concurrent tracker HTTP requests across all endpoints (1-100). |
    field(:max_inflight, :integer, default: @default_max_inflight)
    # @config-reference config-configuration-01 tracker.github.max_inflight_per_endpoint
    # @config-detail tracker.github.max_inflight_per_endpoint | integer | 2 | Cap on concurrent requests to any single tracker endpoint (1-100). Must not exceed `tracker.github.max_inflight`. |
    field(:max_inflight_per_endpoint, :integer, default: @default_max_inflight_per_endpoint)
    # @config-reference config-configuration-01 tracker.github.requests_per_minute
    # @config-detail tracker.github.requests_per_minute | integer | 300 | Requests per minute shared by every consumer of one GitHub token (1-10000). Keep it above the hourly ceiling divided by 60 so sustained pacing never binds before the hourly ceiling; bursts above it still hold; lower it when GitHub answers with secondary rate limits. |
    field(:requests_per_minute, :integer, default: @default_requests_per_minute)
    # @config-reference config-configuration-01 tracker.github.stagger_ms
    # @config-detail tracker.github.stagger_ms | integer | 75 | Delay inserted between tracker requests, in milliseconds (0-5000), so a poll cycle does not burst. |
    field(:stagger_ms, :integer, default: @default_stagger_ms)
    # Per-actor hourly GitHub ceilings (#2181): how many billable Core / GraphQL
    # / search responses one actor may consume in a rolling hour before its own
    # requests hold. `304` responses are reconciled as free; `0` disables the
    # ceiling. GraphQL remains request-counted rather than point-priced, and
    # `search` is a third window (~30 requests/minute) that must not be folded
    # into core or graphql.
    # @config-reference config-configuration-01 tracker.github.daemon_core_limit_per_hour
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.daemon_core_limit_per_hour | integer | 3000 | Hourly billable Core (REST) response ceiling for the daemon actor. A `304` is reconciled as free. When the daemon hits the ceiling, only its requests hold until the rolling hour rolls back under it. `0` disables. |
    field(:daemon_core_limit_per_hour, :integer, default: @default_daemon_core_limit_per_hour)
    # @config-reference config-configuration-01 tracker.github.daemon_graphql_limit_per_hour
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.daemon_graphql_limit_per_hour | integer | 4500 | Hourly billable GraphQL response ceiling for the daemon actor. `0` disables. Raised from 2000 because the guard now books the high-level GraphQL-on-the-wire reads (`gh pr view/list/status/checks`, `gh issue view/list/status`, `gh search issues/prs`, `gh api graphql`) to the GraphQL window, and the App-token daemon alone measures ~3,400-4,300 such requests per hour. |
    field(:daemon_graphql_limit_per_hour, :integer, default: @default_daemon_graphql_limit_per_hour)
    # @config-reference config-configuration-01 tracker.github.daemon_search_limit_per_hour
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.daemon_search_limit_per_hour | integer | 600 | Hourly billable ceiling for GitHub's separate `search` pool (`gh search repos/code/commits/users` hit REST `/search/*`, metered at roughly 30 requests per minute rather than 5,000/hour). `0` disables. |
    field(:daemon_search_limit_per_hour, :integer, default: @default_daemon_search_limit_per_hour)
    # @config-reference config-configuration-01 tracker.github.agent_core_limit_per_hour
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.agent_core_limit_per_hour | integer | 250 | Hourly billable Core (REST) response ceiling for each agent workspace. When one agent hits it, only that agent holds. `0` disables. |
    field(:agent_core_limit_per_hour, :integer, default: @default_agent_core_limit_per_hour)
    # @config-reference config-configuration-01 tracker.github.agent_graphql_limit_per_hour
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.agent_graphql_limit_per_hour | integer | 600 | Hourly billable GraphQL response ceiling for each agent workspace. `0` disables. Raised from 375 so a single agent's normal loop (`pr view`/`issue view`/`pr checks`) has headroom once high-level GraphQL commands book to the GraphQL window. |
    field(:agent_graphql_limit_per_hour, :integer, default: @default_agent_graphql_limit_per_hour)
    # @config-reference config-configuration-01 tracker.github.agent_search_limit_per_hour
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.agent_search_limit_per_hour | integer | 600 | Hourly billable ceiling against the `search` pool for each agent workspace. `0` disables. Kept separate from core and graphql because GitHub meters the search pool independently and it throttles first. |
    field(:agent_search_limit_per_hour, :integer, default: @default_agent_search_limit_per_hour)
    # Additional GitHub credentials the daemon may spread API load across. An
    # empty list is the single-credential default and changes nothing.
    # @config-reference config-configuration-01 tracker.github.credentials
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.github.credentials | array | `[]` | Additional GitHub credentials the daemon spreads read traffic across, so one exhausted budget does not stop the fleet. Empty — the default — means one credential resolved exactly as before. See [Credential pooling](/apis/github-budgets#credential-pooling). |
    embeds_many(:credentials, GithubCredential, on_replace: :delete)
    # Optional. Present only when the daemon authenticates as a GitHub App and
    # therefore writes under a login the agents do not hold. Absent is the
    # single-identity default: everything resolves to `bot_account`.
    embeds_one(:github_app, GithubApp, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      Map.update(attrs, "allowed_contributors", nil, fn
        nil -> %{}
        value -> value
      end),
      [
        :repo,
        :label_prefix,
        :bot_account,
        :identity_mode,
        :trusted_accounts,
        :allowed_users,
        :allowed_contributors,
        :human_mergers,
        :planning_root_limit,
        :planning_page_budget,
        :planning_call_budget,
        :max_inflight,
        :max_inflight_per_endpoint,
        :requests_per_minute,
        :stagger_ms,
        :daemon_core_limit_per_hour,
        :daemon_graphql_limit_per_hour,
        :daemon_search_limit_per_hour,
        :agent_core_limit_per_hour,
        :agent_graphql_limit_per_hour,
        :agent_search_limit_per_hour
      ],
      empty_values: []
    )
    |> validate_required([
      :planning_root_limit,
      :planning_page_budget,
      :planning_call_budget,
      :max_inflight,
      :max_inflight_per_endpoint,
      :requests_per_minute,
      :stagger_ms,
      :daemon_core_limit_per_hour,
      :daemon_graphql_limit_per_hour,
      :daemon_search_limit_per_hour,
      :agent_core_limit_per_hour,
      :agent_graphql_limit_per_hour,
      :agent_search_limit_per_hour
    ])
    |> cast_embed(:credentials, with: &GithubCredential.changeset/2)
    |> cast_embed(:github_app, with: &GithubApp.changeset/2)
    |> validate_unique_credential_ids()
    |> validate_inclusion(:identity_mode, ["separate_account", "single_account"], message: "must be \"separate_account\" or \"single_account\"")
    |> validate_allowed_contributors()
    |> validate_login_list(:allowed_users)
    |> validate_login_list(:human_mergers)
    |> validate_number(:planning_root_limit,
      greater_than: 0,
      less_than_or_equal_to: @max_planning_root_limit
    )
    |> validate_number(:planning_page_budget,
      greater_than: 0,
      less_than_or_equal_to: @max_planning_page_budget
    )
    |> validate_number(:planning_call_budget,
      greater_than: 0,
      less_than_or_equal_to: @max_planning_call_budget
    )
    |> validate_number(:max_inflight, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:max_inflight_per_endpoint, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:requests_per_minute, greater_than: 0, less_than_or_equal_to: 10_000)
    |> validate_number(:stagger_ms, greater_than_or_equal_to: 0, less_than_or_equal_to: 5_000)
    |> validate_number(:daemon_core_limit_per_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:daemon_graphql_limit_per_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:daemon_search_limit_per_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:agent_core_limit_per_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:agent_graphql_limit_per_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:agent_search_limit_per_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 100_000)
    |> validate_endpoint_concurrency()
  end

  defp validate_allowed_contributors(changeset) do
    case fetch_change(changeset, :allowed_contributors) do
      {:ok, value} ->
        case AllowedContributorsParser.from_config(value) do
          {:ok, _list} -> changeset
          {:error, message} -> add_error(changeset, :allowed_contributors, message)
        end

      :error ->
        changeset
    end
  end

  # Credential ids name rows in `aiur github-usage` and select a credential in
  # config; two credentials sharing one id makes both reports ambiguous.
  defp validate_unique_credential_ids(changeset) do
    ids = changeset |> get_field(:credentials) |> List.wrap() |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1)

    if length(Enum.uniq(ids)) == length(ids) do
      changeset
    else
      add_error(changeset, :credentials, "credential ids must be unique")
    end
  end

  defp validate_endpoint_concurrency(changeset) do
    global = get_field(changeset, :max_inflight)
    endpoint = get_field(changeset, :max_inflight_per_endpoint)

    if is_integer(global) and is_integer(endpoint) and endpoint > global do
      add_error(changeset, :max_inflight_per_endpoint, "must not exceed max_inflight")
    else
      changeset
    end
  end

  defp validate_login_list(changeset, field) do
    validate_change(changeset, field, fn ^field, users ->
      if Enum.all?(users, &(is_binary(&1) and String.trim(&1) != "")),
        do: [],
        else: [{field, "must contain non-empty GitHub logins"}]
    end)
  end
end

defmodule Aiur.Config.Schema.Linear do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-01 tracker.linear.api_key
    # @config-detail tracker.linear.api_key | string | env fallback | Linear API key; `$VAR` resolves from the environment. |
    field(:api_key, :string)
    # @config-reference config-configuration-01 tracker.linear.project_slug
    # @config-detail tracker.linear.project_slug | string | nil | Linear project polled by Aiur. |
    field(:project_slug, :string)
    # @config-reference config-configuration-01 tracker.linear.endpoint
    # @config-detail tracker.linear.endpoint | string | `https://api.linear.app/graphql` | Linear GraphQL endpoint. |
    field(:endpoint, :string, default: "https://api.linear.app/graphql")
    # @config-reference config-configuration-01 tracker.linear.assignee
    # @config-detail tracker.linear.assignee | string | env fallback | Linear assignee filter. |
    field(:assignee, :string)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:api_key, :project_slug, :endpoint, :assignee], empty_values: [])
  end
end

defmodule Aiur.Config.Schema.Tracker do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.Schema.{Github, Linear}

  @primary_key false

  embedded_schema do
    # @config-reference config-configuration-01 tracker.kind
    # @config-detail tracker.kind | string | required | Selects `linear`, `github`, or `memory`. |
    field(:kind, :string)
    # @config-reference config-configuration-01 tracker.base_branch
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.base_branch | string | required | Branch agents target with PRs. `aiur init` offers the repository default read from GitHub, but there is no runtime fallback: an unset value raises. |
    field(:base_branch, :string)
    # @config-reference config-configuration-01 tracker.restack_after_blocker_merge
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.restack_after_blocker_merge | boolean | true | Fast-forward restack idle GitHub dependents after a blocker squash-merges. Requires git 2.40+. Live agents restack themselves; false disables only the daemon path. |
    field(:restack_after_blocker_merge, :boolean, default: true)
    # @config-reference config-configuration-01 tracker.propagate_blocker_pushes
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail tracker.propagate_blocker_pushes | boolean or nil | nil | Unset enables optimistic queue members; otherwise false. Cascade direct blocker pushes into idle dependents. Coalesces for 2 seconds, at most 2 propagations concurrently. Live agents pull themselves; conflicts dispatch rework. |
    field(:propagate_blocker_pushes, :boolean)
    # @config-reference config-configuration-01 tracker.active_states
    # @config-detail tracker.active_states | array | tracker-specific | States eligible for dispatch. GitHub values are lifecycle label slugs such as `todo` and `in-progress`, not display names. |
    field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
    # @config-reference config-configuration-01 tracker.terminal_states
    # @config-detail tracker.terminal_states | array | tracker-specific | States that stop work. GitHub values are lifecycle label slugs such as `done`. |
    field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])

    # How long a terminal tracker observation (e.g. GitHub `closed`) stays
    # lifecycle-fenced while a queued authoritative item is still undelivered,
    # before the daemon finalizes the running entry. Bounds the R4 protection
    # window so an externally-closed ticket is released promptly after it
    # expires. Operators with longer provider turn-delivery latency can raise it.
    # @config-reference config-configuration-01 tracker.terminal_fence_grace_seconds
    # @config-detail tracker.terminal_fence_grace_seconds | integer | 30 | How long a terminal tracker observation remains lifecycle-fenced while an authoritative queued item is still undelivered. |
    field(:terminal_fence_grace_seconds, :integer, default: 30)

    embeds_one(:github, Github, on_replace: :update, defaults_to_struct: true)
    embeds_one(:linear, Linear, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [:kind, :base_branch, :restack_after_blocker_merge, :propagate_blocker_pushes, :active_states, :terminal_states, :terminal_fence_grace_seconds],
      empty_values: []
    )
    |> cast_embed(:github, with: &Github.changeset/2)
    |> cast_embed(:linear, with: &Linear.changeset/2)
  end
end
