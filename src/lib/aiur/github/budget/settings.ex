defmodule Aiur.GitHub.Budget.Settings do
  @moduledoc false

  alias Aiur.GitHub.Access.Settings, as: AccessSettings
  alias Aiur.GitHub.Budget

  @default_max_inflight 4
  @default_max_inflight_per_endpoint 2
  @default_requests_per_minute 300
  @default_stagger_ms 75
  @default_timeout_ms 30_000
  @lease_grace_ms 5_000
  # Per-actor hourly ceilings (#2181): how many billable Core / GraphQL /
  # search responses one actor (the daemon, or each agent workspace) may consume
  # in a rolling hour before its own requests hold. A completed `304` is
  # reconciled as free. These remain request counts, not GraphQL point budgets.
  # `0` disables a ceiling.
  #
  # The GraphQL defaults were raised in #2299 because the guard now books the
  # high-level `gh` reads (`pr view|list|status|checks`, `issue view|list`,
  # `gh api graphql`) to the GraphQL window: the App-token daemon measured
  # ~3,400-4,300 GraphQL-wire requests/hour, so the pre-fix daemon default of
  # 2,000 would have stalled the fleet on merge. The agent GraphQL ceiling is
  # raised too so a single agent's normal loop has headroom under the re-booked
  # window. These stay request counts, never GraphQL point budgets. `search` is
  # a third, much lower GitHub window (~30 requests/minute), so it gets its own
  # ceiling instead of folding into core or graphql.
  @default_daemon_core_limit_per_hour 3000
  @default_daemon_graphql_limit_per_hour 4500
  @default_daemon_search_limit_per_hour 600
  @default_agent_core_limit_per_hour 250
  @default_agent_graphql_limit_per_hour 600
  @default_agent_search_limit_per_hour 600

  @spec settings(keyword()) :: map()
  def settings(opts) do
    github = github_settings(opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    lease_timeout_ms = Keyword.get(opts, :lease_timeout_ms, timeout_ms)

    %{
      max_inflight: positive(Keyword.get(opts, :max_inflight, Map.get(github, :max_inflight, @default_max_inflight)), @default_max_inflight),
      max_inflight_per_endpoint:
        positive(
          Keyword.get(opts, :max_inflight_per_endpoint, Map.get(github, :max_inflight_per_endpoint, @default_max_inflight_per_endpoint)),
          @default_max_inflight_per_endpoint
        ),
      requests_per_minute:
        positive(
          Keyword.get(opts, :requests_per_minute, Map.get(github, :requests_per_minute, @default_requests_per_minute)),
          @default_requests_per_minute
        ),
      stagger_ms: nonnegative(Keyword.get(opts, :stagger_ms, Map.get(github, :stagger_ms, @default_stagger_ms)), @default_stagger_ms),
      lease_ttl_ms: positive(lease_timeout_ms, @default_timeout_ms) * 2 + @lease_grace_ms,
      daemon_core_limit_per_hour:
        nonnegative(
          Keyword.get(opts, :daemon_core_limit_per_hour, Map.get(github, :daemon_core_limit_per_hour, @default_daemon_core_limit_per_hour)),
          @default_daemon_core_limit_per_hour
        ),
      daemon_graphql_limit_per_hour:
        nonnegative(
          Keyword.get(opts, :daemon_graphql_limit_per_hour, Map.get(github, :daemon_graphql_limit_per_hour, @default_daemon_graphql_limit_per_hour)),
          @default_daemon_graphql_limit_per_hour
        ),
      daemon_search_limit_per_hour:
        nonnegative(
          Keyword.get(opts, :daemon_search_limit_per_hour, Map.get(github, :daemon_search_limit_per_hour, @default_daemon_search_limit_per_hour)),
          @default_daemon_search_limit_per_hour
        ),
      agent_core_limit_per_hour:
        nonnegative(
          Keyword.get(opts, :agent_core_limit_per_hour, Map.get(github, :agent_core_limit_per_hour, @default_agent_core_limit_per_hour)),
          @default_agent_core_limit_per_hour
        ),
      agent_graphql_limit_per_hour:
        nonnegative(
          Keyword.get(opts, :agent_graphql_limit_per_hour, Map.get(github, :agent_graphql_limit_per_hour, @default_agent_graphql_limit_per_hour)),
          @default_agent_graphql_limit_per_hour
        ),
      agent_search_limit_per_hour:
        nonnegative(
          Keyword.get(opts, :agent_search_limit_per_hour, Map.get(github, :agent_search_limit_per_hour, @default_agent_search_limit_per_hour)),
          @default_agent_search_limit_per_hour
        )
    }
  end

  defp github_settings(opts) do
    case Keyword.get(opts, :github_settings, Application.get_env(:aiur, :github_budget_settings_override)) do
      %{max_inflight: _value} = settings ->
        settings

      _ ->
        AccessSettings.current().budget
    end
  rescue
    _unavailable -> %{}
  end

  @spec deadline(keyword()) :: integer()
  def deadline(opts), do: System.monotonic_time(:millisecond) + positive(Keyword.get(opts, :timeout_ms, @default_timeout_ms), @default_timeout_ms)

  @spec command_deadline(keyword()) :: integer()
  def command_deadline(opts) do
    Keyword.get_lazy(opts, :deadline_at, fn -> deadline(opts) end)
  end

  @spec consumer_identity(keyword()) :: String.t()
  def consumer_identity(opts) do
    Keyword.get(opts, :consumer_key) ||
      System.get_env("AIUR_GITHUB_BUDGET_CONSUMER") ||
      "daemon:#{node()}"
  end

  @spec consumer_key(keyword()) :: String.t()
  def consumer_key(opts), do: Budget.token_key(consumer_identity(opts))

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
  defp nonnegative(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value, default), do: default
end
