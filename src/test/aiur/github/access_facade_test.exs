defmodule Aiur.GitHub.AccessFacadeTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Access
  alias Aiur.GitHub.Access.{Settings, StaticSettings}
  alias Aiur.GitHub.ResourceStore

  @moduletag :tmp_dir

  @delegates [
    {:app_id, Aiur.GitHub.AppCredentials, :app_id},
    {:app_configured?, Aiur.GitHub.AppCredentials, :configured?},
    {:installation_id, Aiur.GitHub.AppCredentials, :installation_id},
    {:app_private_key, Aiur.GitHub.AppCredentials, :parse_private_key},
    {:app_jwt, Aiur.GitHub.AppToken, :app_jwt},
    {:ensure_preflight, Aiur.GitHub.AuthPreflight, :ensure_preflight},
    {:format_auth_preflight_error, Aiur.GitHub.AuthPreflight, :format_auth_preflight_error},
    {:local_hold_reason?, Aiur.GitHub.AuthPreflight, :local_hold_reason?},
    {:preflight_auth, Aiur.GitHub.AuthPreflight, :preflight_auth},
    {:budget_enabled?, Aiur.GitHub.Budget, :enabled?},
    {:ensure_budget_state_dir, Aiur.GitHub.Budget, :ensure_state_dir},
    {:guard_settings, Aiur.GitHub.Budget, :guard_settings},
    {:prioritize, Aiur.GitHub.Budget, :prioritize},
    {:budget_state_dir, Aiur.GitHub.Budget, :state_dir},
    {:token_key, Aiur.GitHub.Budget, :token_key},
    {:usage, Aiur.GitHub.Budget, :usage},
    {:warn_metering_unavailable, Aiur.GitHub.Budget, :warn_metering_unavailable},
    {:ledger_window_ms, Aiur.GitHub.BudgetLedger, :window_ms},
    {:connectivity_alert_message, Aiur.GitHub.Connectivity, :alert_message},
    {:connectivity_backoff_ms, Aiur.GitHub.Connectivity, :backoff_ms},
    {:connectivity_classify_ls_remote, Aiur.GitHub.Connectivity, :classify_ls_remote},
    {:connectivity_max_backoff_ms, Aiur.GitHub.Connectivity, :max_backoff_ms},
    {:connectivity_note_failure, Aiur.GitHub.Connectivity, :note_failure},
    {:connectivity_note_success, Aiur.GitHub.Connectivity, :note_success},
    {:connectivity_record_failure, Aiur.GitHub.Connectivity, :record_failure},
    {:identity_key, Aiur.GitHub.Credential, :identity_key},
    {:token_type, Aiur.GitHub.Credential, :token_type},
    {:credential_pool, Aiur.GitHub.CredentialUsage, :pool},
    {:credential_usage, Aiur.GitHub.CredentialUsage, :rows},
    {:end_cycle, Aiur.GitHub.CycleFetchCache, :end_cycle},
    {:cycle_fetch, Aiur.GitHub.CycleFetchCache, :fetch},
    {:start_cycle, Aiur.GitHub.CycleFetchCache, :start_cycle},
    {:classify_error, Aiur.GitHub.Errors, :classify_error},
    {:github_status_error, Aiur.GitHub.Errors, :github_status_error},
    {:outcome, Aiur.GitHub.Errors, :outcome},
    {:rate_limit_observation, Aiur.GitHub.Errors, :rate_limit_observation},
    {:response_message, Aiur.GitHub.Errors, :response_message},
    {:retryable_github_error?, Aiur.GitHub.Errors, :retryable_github_error?},
    {:transient_github_error?, Aiur.GitHub.Errors, :transient_github_error?},
    {:estimate_graphql_cost, Aiur.GitHub.GraphQLCost, :estimate},
    {:graphql_operation_name, Aiur.GitHub.GraphQLCost, :operation_name},
    {:reported_graphql_cost, Aiur.GitHub.GraphQLCost, :reported},
    {:host_executable, Aiur.GitHub.HostCommand, :find_executable},
    {:host_command, Aiur.GitHub.HostCommand, :run},
    {:backoff_base_ms, Aiur.GitHub.LocalHold, :backoff_base_ms},
    {:transient_retry_opts, Aiur.GitHub.LocalHold, :caller_opts},
    {:with_transient_retry, Aiur.GitHub.LocalHold, :run},
    {:quota_cached_snapshot, Aiur.GitHub.Quota, :cached_snapshot},
    {:quota_cached_snapshot_at, Aiur.GitHub.Quota, :cached_snapshot_at},
    {:dispatch_status, Aiur.GitHub.Quota, :dispatch_status},
    {:cost_report, Aiur.GitHub.Quota, :snapshot!},
    {:invalidate, Aiur.GitHub.ReadCache, :invalidate},
    {:invalidate_number, Aiur.GitHub.ReadCache, :invalidate_number},
    {:invalidate_repo, Aiur.GitHub.ReadCache, :invalidate_repo},
    {:invalidate_repo_config, Aiur.GitHub.ReadCache, :invalidate_repo_config},
    {:pull_request_commits, Aiur.GitHub.ReadCache, :pull_request_commits},
    {:cache_snapshot, Aiur.GitHub.ReadCache, :snapshot},
    {:carry, Aiur.GitHub.RequestOrigin, :carry},
    {:view_originated?, Aiur.GitHub.RequestOrigin, :view_originated?},
    {:subscribe_repo, Aiur.GitHub.ResourceEvents, :subscribe},
    {:resource_decision, Aiur.GitHub.ResourceFetch, :decision},
    {:resource_need, Aiur.GitHub.ResourceFetch, :need},
    {:clear, Aiur.GitHub.ResourceStore, :clear},
    {:data, Aiur.GitHub.ResourceStore, :data},
    {:deposit_unless_older, Aiur.GitHub.ResourceStore, :deposit_unless_older},
    {:drop_data, Aiur.GitHub.ResourceStore, :drop_data},
    {:drop_etag, Aiur.GitHub.ResourceStore, :drop_etag},
    {:etag, Aiur.GitHub.ResourceStore, :etag},
    {:fetch_resource, Aiur.GitHub.ResourceStore, :fetch},
    {:flush, Aiur.GitHub.ResourceStore, :flush},
    {:key, Aiur.GitHub.ResourceStore, :key},
    {:key_for_repo, Aiur.GitHub.ResourceStore, :key_for_repo},
    {:list, Aiur.GitHub.ResourceStore, :list},
    {:list_type, Aiur.GitHub.ResourceStore, :list_type},
    {:mark_processed, Aiur.GitHub.ResourceStore, :mark_processed},
    {:membership_snapshot, Aiur.GitHub.ResourceStore, :membership_snapshot},
    {:processed?, Aiur.GitHub.ResourceStore, :processed?},
    {:put_etag, Aiur.GitHub.ResourceStore, :put_etag},
    {:put_resource, Aiur.GitHub.ResourceStore, :put_resource},
    {:regression?, Aiur.GitHub.ResourceStore, :regression?},
    {:replace_membership, Aiur.GitHub.ResourceStore, :replace_membership},
    {:retention_ms, Aiur.GitHub.ResourceStore, :retention_ms},
    {:revalidate, Aiur.GitHub.ResourceStore, :revalidate},
    {:running?, Aiur.GitHub.ResourceStore, :running?},
    {:subscribe, Aiur.GitHub.ResourceStore, :subscribe},
    {:subscribe_type, Aiur.GitHub.ResourceStore, :subscribe_type},
    {:update_resource, Aiur.GitHub.ResourceStore, :update_resource},
    {:print_status, Aiur.GitHub.ResourceStore.Memory, :print_status},
    {:base_url, Aiur.GitHub.Transport, :base_url},
    {:default_request_fun, Aiur.GitHub.Transport, :default_request_fun},
    {:fetch_json_list, Aiur.GitHub.Transport, :fetch_json_list},
    {:fetch_json_list_conditional, Aiur.GitHub.Transport, :fetch_json_list_conditional},
    {:fetch_json_map, Aiur.GitHub.Transport, :fetch_json_map},
    {:github_graphql, Aiur.GitHub.Transport, :github_graphql},
    {:github_graphql_response, Aiur.GitHub.Transport, :github_graphql_response},
    {:graphql_url, Aiur.GitHub.Transport, :graphql_url},
    {:header, Aiur.GitHub.Transport, :header},
    {:maybe_put_query, Aiur.GitHub.Transport, :maybe_put_query},
    {:parse_next_page_url, Aiur.GitHub.Transport, :parse_next_page_url},
    {:parse_repo, Aiur.GitHub.Transport, :parse_repo},
    {:poll_interval, Aiur.GitHub.Transport, :poll_interval},
    {:put_caller, Aiur.GitHub.Transport, :put_caller},
    {:require_token, Aiur.GitHub.Transport, :require_token},
    {:agent_cache_bridge_child_spec, Aiur.GitHub.AgentCacheBridge, :child_spec},
    {:app_token_refresher_child_spec, Aiur.GitHub.AppTokenRefresher, :child_spec},
    {:broker_timeout_child_spec, Aiur.GitHub.BrokerTimeout, :child_spec},
    {:budget_broker_child_spec, Aiur.GitHub.BudgetBroker, :child_spec},
    {:credential_headroom_child_spec, Aiur.GitHub.CredentialHeadroom, :child_spec},
    {:quota_child_spec, Aiur.GitHub.Quota, :child_spec},
    {:read_cache_child_spec, Aiur.GitHub.ReadCache, :child_spec},
    {:resource_store_child_spec, Aiur.GitHub.ResourceStore, :child_spec}
  ]
  setup %{tmp_dir: root} do
    keys = [:github_access_settings_provider, :github_access_settings]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:aiur, &1)})
    on_exit(fn -> Aiur.TestSupport.restore_app_env(previous) end)
    Application.put_env(:aiur, :github_access_settings_provider, StaticSettings)
    settings = Settings.new(root, repo: "facade/test", budget_enabled?: false, write_scope: fn request, _execute -> {:ok, request} end)
    Application.put_env(:aiur, :github_access_settings, settings)
    key = ResourceStore.key(:issue_comment, "facade", "test", System.unique_integer([:positive]))
    on_exit(fn -> ResourceStore.forget(key) end)
    wrapper = Path.join(root, "gh")
    File.write!(wrapper, "#!/bin/sh\nprintf 'facade command'\n")
    File.chmod!(wrapper, 0o700)
    %{root: root, key: key}
  end

  for {facade, target, function} <- @delegates do
    test "#{facade} returns #{inspect(target)}.#{function}'s value", ctx do
      args = fixture_args(unquote(facade), ctx)
      # Reset the resource between calls so writes cannot change the comparison's input.
      ResourceStore.forget(ctx.key)
      expected = apply(unquote(target), unquote(function), args)
      ResourceStore.forget(ctx.key)
      actual = apply(Access, unquote(facade), args)
      assert actual == expected
    end
  end

  test "credential construction and quota identity preserve the underlying values" do
    fields = [id: "facade", kind: :machine_user, identity: "agent", writes?: true]
    assert Access.credential(fields) == struct!(Aiur.GitHub.Credential, fields)
    assert Access.quota_server() == Aiur.GitHub.Quota
  end

  test "resource writes and reads share the same store", %{key: key} do
    body = %{"id" => 73, "body" => "facade resource"}
    assert :ok = Access.put_resource(key, body, source: :fetch)
    assert {:ok, %{data: ^body}} = Access.fetch_resource(key)
    assert Access.data(key) == body
    assert ResourceStore.data(key) == body
  end

  test "with_transient_retry waits out one hold and returns the successful value" do
    now = DateTime.utc_now()
    parent = self()
    counter = :counters.new(1, [])

    attempt = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) == 1, do: {:error, {:github, :local_hold, %{hold: %{reset_at: DateTime.add(now, 1, :second)}}}}, else: {:ok, :retried}
    end

    assert Access.with_transient_retry(attempt, now_fun: fn -> now end, sleep_fun: fn ms -> send(parent, {:waited, ms}) end) == {:ok, :retried}
    assert :counters.get(counter, 1) == 2
    assert_received {:waited, ms}
    assert ms in 1_000..1_500
  end

  defp fixture_args(name, _ctx)
       when name in [
              :agent_cache_bridge_child_spec,
              :app_token_refresher_child_spec,
              :broker_timeout_child_spec,
              :budget_broker_child_spec,
              :credential_headroom_child_spec,
              :quota_child_spec,
              :read_cache_child_spec,
              :resource_store_child_spec
            ],
       do: [[]]

  defp fixture_args(:app_jwt, _ctx), do: [JOSE.JWK.generate_key({:rsa, 2048}), "facade", DateTime.utc_now()]

  defp fixture_args(:cost_report, ctx) do
    now = DateTime.utc_now()

    quota =
      start_supervised!(
        {Aiur.GitHub.Quota,
         name: nil,
         refresh?: false,
         request_log_path: nil,
         clock: fn -> now end,
         hold_dir: ctx.root,
         shell_log_path: Path.join(ctx.root, "shell.ndjson"),
         stale_broker_path: Path.join(ctx.root, "stale.json")}
      )

    [quota, 1_000]
  end

  defp fixture_args(name, ctx) do
    ok = fn _request -> {:ok, %{status: 200, body: %{"data" => %{"node" => "fixture"}}, headers: []}} end
    list = fn _request -> {:ok, %{status: 200, body: [%{"id" => 73}], headers: []}} end
    map = fn _request -> {:ok, %{status: 200, body: %{"id" => 73}, headers: []}} end
    opts = [state_dir: ctx.root, enabled?: false]
    response = %{status: 429, body: %{"message" => "rate limit exceeded"}, headers: [{"x-ratelimit-remaining", "0"}]}

    Map.fetch!(
      %{
        app_id: [],
        app_configured?: [],
        installation_id: [],
        app_private_key: [],
        ensure_preflight: [[request_fun: ok]],
        preflight_auth: [[request_fun: ok]],
        format_auth_preflight_error: [:missing_github_token],
        local_hold_reason?: [:timeout],
        budget_enabled?: [opts],
        ensure_budget_state_dir: [opts],
        guard_settings: [opts],
        prioritize: [],
        budget_state_dir: [opts],
        token_key: ["fixture-token"],
        usage: [opts],
        warn_metering_unavailable: [opts],
        ledger_window_ms: [],
        connectivity_alert_message: [%{source: :poll, classification: :dns, count: 3}, []],
        connectivity_backoff_ms: [:auth, 2, %{}],
        connectivity_classify_ls_remote: [{:git_ls_remote_timeout, 100}],
        connectivity_max_backoff_ms: [],
        connectivity_note_failure: [%{}, :poll, :dns],
        connectivity_note_success: [%{poll: {:dns, 1}}, :poll],
        connectivity_record_failure: [%{}, :poll, :dns, 100, [emit_fun: fn _, _, _ -> :ok end]],
        identity_key: [struct!(Aiur.GitHub.Credential, id: "facade", kind: :machine_user)],
        token_type: ["github_pat_fixture"],
        credential_pool: [[rows: []]],
        credential_usage: [[credentials: [], usage_fun: fn -> %{actors: []} end]],
        start_cycle: [],
        end_cycle: [],
        cycle_fetch: [:facade, fn -> {:ok, :cycle} end],
        classify_error: [{:error, :nxdomain}],
        github_status_error: [response],
        outcome: [{:error, {:aiur, :unknown, :fixture}}],
        rate_limit_observation: [response],
        response_message: [response],
        retryable_github_error?: [{:github, :dns, %{}}],
        transient_github_error?: [{:github, :auth, %{}}],
        estimate_graphql_cost: [%{body: %{query: "query { viewer { login } }"}}],
        graphql_operation_name: ["query Facade { viewer { login } }"],
        reported_graphql_cost: [%{"data" => %{"rateLimit" => %{"cost" => 7}}}],
        host_executable: [[wrapper_dir: ctx.root]],
        host_command: [["fixture"], [wrapper_dir: ctx.root]],
        backoff_base_ms: [],
        transient_retry_opts: [[max_waits: 1]],
        with_transient_retry: [fn -> {:ok, :fixture} end, []],
        quota_cached_snapshot: [:facade_missing_server, 0],
        quota_cached_snapshot_at: [:facade_missing_server, 0, 0],
        dispatch_status: [:facade_missing_server],
        invalidate: ["facade/test"],
        invalidate_number: ["facade/test", 73],
        invalidate_repo: ["facade/test"],
        invalidate_repo_config: ["facade/test"],
        pull_request_commits: [nil, 73, "head", fn -> {:ok, :commits} end],
        cache_snapshot: [],
        carry: [true, fn -> :carried end],
        view_originated?: [],
        subscribe: [nil],
        subscribe_repo: [:issue_comment, "facade/test"],
        resource_decision: [],
        resource_need: [ctx.key, fn _opts -> {:error, :facade_fixture} end, [freshness: :strict]],
        clear: [:issue_comment, "facade", "test"],
        data: [ctx.key],
        deposit_unless_older: [ctx.key, %{"id" => 73}, [source: :fetch]],
        drop_data: [ctx.key],
        drop_etag: [ctx.key],
        etag: [ctx.key],
        fetch_resource: [ctx.key],
        flush: [],
        key: [:issue_comment, "facade", "test", 73],
        key_for_repo: [:issue_comment, "facade/test", 73],
        list: [:issue_comment, "facade", "test"],
        list_type: [:issue_comment, "facade/test"],
        mark_processed: [ctx.key, :fetch, "v1"],
        membership_snapshot: ["facade", "test"],
        processed?: [ctx.key, "v1"],
        put_etag: [ctx.key, "etag", :any],
        put_resource: [ctx.key, %{"id" => 73}, [source: :fetch]],
        regression?: [nil, "v1"],
        replace_membership: ["facade", "test", %{}, []],
        retention_ms: [],
        revalidate: [ctx.key, %{"id" => 73}, "etag"],
        running?: [],
        subscribe_type: [:issue_comment],
        update_resource: [ctx.key, fn _old -> %{"id" => 73} end, [source: :fetch]],
        print_status: [],
        base_url: [],
        default_request_fun: [%{method: :get, url: "fixture"}],
        fetch_json_list: [list, "fixture", "https://fixture/list", []],
        fetch_json_list_conditional: [list, "fixture", "https://fixture/list", nil, []],
        fetch_json_map: [map, "fixture", "https://fixture/map", []],
        github_graphql: [ok, "fixture", "query { node }", %{}, []],
        github_graphql_response: [ok, "fixture", "query { node }", %{}, []],
        graphql_url: [],
        header: [[{"etag", "fixture"}], "etag"],
        maybe_put_query: [%{}, :fixture, "value"],
        parse_next_page_url: [[{"link", "<https://fixture/page2>; rel=\"next\""}]],
        parse_repo: [],
        poll_interval: [[{"x-poll-interval", "60"}]],
        put_caller: [%{method: :get}, [caller: "facade"]],
        require_token: [[token: "fixture"]]
      },
      name
    )
  end
end
