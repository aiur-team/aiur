defmodule Aiur.GitHub.Access do
  @moduledoc """
  Public GitHub access contract. Requests, resources, budgets and diagnostics
  preserve the underlying access layer's results and error terms.
  """

  @type classification :: Aiur.GitHub.Errors.classification()
  @type key :: Aiur.GitHub.ResourceStore.key()
  @type resource_type :: Aiur.GitHub.ResourceStore.resource_type()

  defdelegate app_id(), to: Aiur.GitHub.AppCredentials
  defdelegate app_configured?(), to: Aiur.GitHub.AppCredentials, as: :configured?
  defdelegate installation_id(), to: Aiur.GitHub.AppCredentials
  defdelegate app_private_key(), to: Aiur.GitHub.AppCredentials, as: :parse_private_key
  defdelegate app_jwt(jwk, app_id, now \\ DateTime.utc_now()), to: Aiur.GitHub.AppToken
  defdelegate ensure_preflight(opts \\ []), to: Aiur.GitHub.AuthPreflight
  defdelegate format_auth_preflight_error(reason), to: Aiur.GitHub.AuthPreflight
  defdelegate local_hold_reason?(reason), to: Aiur.GitHub.AuthPreflight
  defdelegate preflight_auth(opts \\ []), to: Aiur.GitHub.AuthPreflight
  defdelegate budget_enabled?(opts \\ []), to: Aiur.GitHub.Budget, as: :enabled?
  defdelegate ensure_budget_state_dir(opts \\ []), to: Aiur.GitHub.Budget, as: :ensure_state_dir
  defdelegate guard_settings(opts \\ []), to: Aiur.GitHub.Budget
  defdelegate prioritize(), to: Aiur.GitHub.Budget
  defdelegate budget_state_dir(opts \\ []), to: Aiur.GitHub.Budget, as: :state_dir
  defdelegate token_key(token), to: Aiur.GitHub.Budget
  defdelegate usage(opts \\ []), to: Aiur.GitHub.Budget
  defdelegate warn_metering_unavailable(opts \\ []), to: Aiur.GitHub.Budget
  defdelegate fleet_budget_snapshot(), to: Aiur.GitHub.Budget.FleetSnapshot, as: :read
  defdelegate fleet_budget_status_line(configured?), to: Aiur.GitHub.Budget.FleetSnapshot, as: :status_line
  defdelegate ledger_window_ms(), to: Aiur.GitHub.BudgetLedger, as: :window_ms

  defdelegate connectivity_alert_message(arg1, opts \\ []),
    to: Aiur.GitHub.Connectivity,
    as: :alert_message

  defdelegate connectivity_backoff_ms(classification, attempt, detail),
    to: Aiur.GitHub.Connectivity,
    as: :backoff_ms

  defdelegate connectivity_classify_ls_remote(reason),
    to: Aiur.GitHub.Connectivity,
    as: :classify_ls_remote

  defdelegate connectivity_max_backoff_ms(), to: Aiur.GitHub.Connectivity, as: :max_backoff_ms

  defdelegate connectivity_note_failure(streaks, source, classification),
    to: Aiur.GitHub.Connectivity,
    as: :note_failure

  defdelegate connectivity_note_success(streaks, source),
    to: Aiur.GitHub.Connectivity,
    as: :note_success

  defdelegate connectivity_record_failure(
                streaks,
                source,
                classification,
                base_interval_ms,
                opts \\ []
              ), to: Aiur.GitHub.Connectivity, as: :record_failure

  defdelegate identity_key(credential), to: Aiur.GitHub.Credential
  defdelegate token_type(token), to: Aiur.GitHub.Credential
  defdelegate credential_pool(opts \\ []), to: Aiur.GitHub.CredentialUsage, as: :pool
  defdelegate credential_usage(opts \\ []), to: Aiur.GitHub.CredentialUsage, as: :rows
  defdelegate end_cycle(), to: Aiur.GitHub.CycleFetchCache
  defdelegate cycle_fetch(key, fetcher), to: Aiur.GitHub.CycleFetchCache, as: :fetch
  defdelegate start_cycle(), to: Aiur.GitHub.CycleFetchCache
  defdelegate classify_error(response), to: Aiur.GitHub.Errors
  defdelegate github_status_error(response), to: Aiur.GitHub.Errors
  defdelegate outcome(result), to: Aiur.GitHub.Errors
  defdelegate rate_limit_observation(response), to: Aiur.GitHub.Errors
  defdelegate response_message(response), to: Aiur.GitHub.Errors
  defdelegate retryable_github_error?(reason), to: Aiur.GitHub.Errors
  defdelegate transient_github_error?(reason), to: Aiur.GitHub.Errors
  defdelegate estimate_graphql_cost(query), to: Aiur.GitHub.GraphQLCost, as: :estimate
  defdelegate graphql_operation_name(query), to: Aiur.GitHub.GraphQLCost, as: :operation_name
  defdelegate reported_graphql_cost(response), to: Aiur.GitHub.GraphQLCost, as: :reported
  defdelegate host_executable(opts \\ []), to: Aiur.GitHub.HostCommand, as: :find_executable
  defdelegate host_command(args, opts \\ []), to: Aiur.GitHub.HostCommand, as: :run
  defdelegate backoff_base_ms(), to: Aiur.GitHub.LocalHold
  defdelegate transient_retry_opts(opts), to: Aiur.GitHub.LocalHold, as: :caller_opts
  defdelegate with_transient_retry(attempt_fun, opts \\ []), to: Aiur.GitHub.LocalHold, as: :run

  defdelegate quota_cached_snapshot(server \\ Aiur.GitHub.Quota, max_age_ms \\ 60_000),
    to: Aiur.GitHub.Quota,
    as: :cached_snapshot

  defdelegate quota_cached_snapshot_at(server, max_age_ms, now_ms),
    to: Aiur.GitHub.Quota,
    as: :cached_snapshot_at

  defdelegate quota_snapshot(server \\ Aiur.GitHub.Quota), to: Aiur.GitHub.Quota, as: :snapshot

  defdelegate dispatch_status(server \\ Aiur.GitHub.Quota), to: Aiur.GitHub.Quota

  defdelegate cost_report(server \\ Aiur.GitHub.Quota, timeout \\ 5000),
    to: Aiur.GitHub.Quota,
    as: :snapshot!

  defdelegate invalidate(identities), to: Aiur.GitHub.ReadCache
  defdelegate invalidate_number(full_name, number), to: Aiur.GitHub.ReadCache
  defdelegate invalidate_repo(full_name), to: Aiur.GitHub.ReadCache
  defdelegate invalidate_repo_config(full_name), to: Aiur.GitHub.ReadCache
  defdelegate pull_request_commits(repo, number, head_sha, fetch), to: Aiur.GitHub.ReadCache
  defdelegate cache_snapshot(), to: Aiur.GitHub.ReadCache, as: :snapshot
  defdelegate carry(origin, fun), to: Aiur.GitHub.RequestOrigin
  defdelegate view_originated?(), to: Aiur.GitHub.RequestOrigin
  defdelegate subscribe_repo(type, full_name), to: Aiur.GitHub.ResourceEvents, as: :subscribe
  defdelegate resource_decision(), to: Aiur.GitHub.ResourceFetch, as: :decision
  defdelegate resource_need(key, fetcher, opts), to: Aiur.GitHub.ResourceFetch, as: :need
  defdelegate clear(resource_type, owner, repo), to: Aiur.GitHub.ResourceStore
  defdelegate data(key), to: Aiur.GitHub.ResourceStore
  defdelegate deposit_unless_older(key, data, opts \\ []), to: Aiur.GitHub.ResourceStore
  defdelegate drop_data(key), to: Aiur.GitHub.ResourceStore
  defdelegate drop_etag(key), to: Aiur.GitHub.ResourceStore
  defdelegate etag(key), to: Aiur.GitHub.ResourceStore
  defdelegate fetch_resource(key), to: Aiur.GitHub.ResourceStore, as: :fetch
  defdelegate flush(server \\ Aiur.GitHub.ResourceStore), to: Aiur.GitHub.ResourceStore
  defdelegate key(resource_type, owner, repo, id), to: Aiur.GitHub.ResourceStore
  defdelegate key_for_repo(resource_type, full_name, id), to: Aiur.GitHub.ResourceStore
  defdelegate list(resource_type, owner, repo), to: Aiur.GitHub.ResourceStore
  defdelegate list_type(type, full_name), to: Aiur.GitHub.ResourceStore
  defdelegate mark_processed(key, source, version \\ nil), to: Aiur.GitHub.ResourceStore
  defdelegate membership_snapshot(owner, repo), to: Aiur.GitHub.ResourceStore
  defdelegate processed?(key, version \\ nil), to: Aiur.GitHub.ResourceStore
  defdelegate put_etag(key, etag, previous \\ :any), to: Aiur.GitHub.ResourceStore
  defdelegate put_resource(key, data, opts \\ []), to: Aiur.GitHub.ResourceStore
  defdelegate regression?(held, version), to: Aiur.GitHub.ResourceStore
  defdelegate replace_membership(owner, repo, expected, edges), to: Aiur.GitHub.ResourceStore
  defdelegate retention_ms(), to: Aiur.GitHub.ResourceStore
  defdelegate revalidate(key, confirmed_data, etag), to: Aiur.GitHub.ResourceStore
  defdelegate running?(), to: Aiur.GitHub.ResourceStore
  defdelegate subscribe(key_or_type), to: Aiur.GitHub.ResourceStore
  defdelegate subscribe_type(type), to: Aiur.GitHub.ResourceStore
  defdelegate update_resource(key, fun, opts \\ []), to: Aiur.GitHub.ResourceStore
  defdelegate print_status(), to: Aiur.GitHub.ResourceStore.Memory
  defdelegate base_url(), to: Aiur.GitHub.Transport
  defdelegate default_request_fun(req), to: Aiur.GitHub.Transport
  defdelegate off_process_request(request, request_fun), to: Aiur.GitHub.Transport
  defdelegate fetch_json_list(request_fun, token, url, opts \\ []), to: Aiur.GitHub.Transport

  defdelegate fetch_json_list_conditional(request_fun, token, url, etag \\ nil, opts \\ []),
    to: Aiur.GitHub.Transport

  defdelegate fetch_json_map(request_fun, token, url, opts \\ []), to: Aiur.GitHub.Transport

  defdelegate github_graphql(request_fun, token, query, variables, opts \\ []),
    to: Aiur.GitHub.Transport

  defdelegate github_graphql_response(request_fun, token, query, variables, opts \\ []),
    to: Aiur.GitHub.Transport

  defdelegate graphql_url(), to: Aiur.GitHub.Transport
  defdelegate header(headers, name), to: Aiur.GitHub.Transport
  defdelegate maybe_put_query(query, key, value), to: Aiur.GitHub.Transport
  defdelegate parse_next_page_url(headers), to: Aiur.GitHub.Transport
  defdelegate parse_repo(), to: Aiur.GitHub.Transport
  defdelegate poll_interval(headers), to: Aiur.GitHub.Transport
  defdelegate put_caller(request, opts), to: Aiur.GitHub.Transport
  defdelegate require_token(), to: Aiur.GitHub.Transport
  defdelegate require_token(opts), to: Aiur.GitHub.Transport

  @spec credential(keyword()) :: Aiur.GitHub.Credential.t()
  def credential(fields), do: struct!(Aiur.GitHub.Credential, fields)

  @spec quota_server() :: module()
  def quota_server, do: Aiur.GitHub.Quota

  defdelegate agent_cache_bridge_child_spec(opts),
    to: Aiur.GitHub.AgentCacheBridge,
    as: :child_spec

  defdelegate app_token_refresher_child_spec(opts),
    to: Aiur.GitHub.AppTokenRefresher,
    as: :child_spec

  defdelegate broker_timeout_child_spec(opts), to: Aiur.GitHub.BrokerTimeout, as: :child_spec
  defdelegate budget_broker_child_spec(opts), to: Aiur.GitHub.BudgetBroker, as: :child_spec

  defdelegate credential_headroom_child_spec(opts),
    to: Aiur.GitHub.CredentialHeadroom,
    as: :child_spec

  defdelegate quota_child_spec(opts), to: Aiur.GitHub.Quota, as: :child_spec
  defdelegate read_cache_child_spec(opts), to: Aiur.GitHub.ReadCache, as: :child_spec
  defdelegate resource_store_child_spec(opts), to: Aiur.GitHub.ResourceStore, as: :child_spec
end
