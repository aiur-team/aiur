defmodule Aiur.GitHub.TestTicketScopeTest do
  use Aiur.TestSupport

  alias Aiur.AgentGitHubGuard.AgentToken
  alias Aiur.Config.Paths, as: ConfigPaths
  alias Aiur.Executor.StatePaths
  alias Aiur.GitHub.{Budget, Config, TestTicketScopeProjectIdentity, TestTicketScopeTracker, Transport}
  alias Aiur.Orchestrator.TicketTransition

  setup do
    previous_scope = System.get_env("AIUR_DEV_TEST_TICKET_IDS")
    previous_state = System.get_env("AIUR_DEV_TEST_STATE_DIR")
    previous_instance = System.get_env("AIUR_INSTANCE_KEY")
    previous_budget = System.get_env("AIUR_GITHUB_BUDGET_DIR")
    previous_app_budget = Application.get_env(:aiur, :github_budget_dir)
    previous_req_options = Application.get_env(:aiur, :github_transport_test_options)
    sandbox_budget = Path.join(System.tmp_dir!(), "aiur-test-budget-test-#{System.unique_integer([:positive])}")
    sandbox_state = Path.join(System.tmp_dir!(), "aiur-test-state-test-#{System.unique_integer([:positive])}")
    System.put_env("AIUR_DEV_TEST_TICKET_IDS", "99,100,101")
    System.put_env("AIUR_DEV_TEST_STATE_DIR", sandbox_state)
    System.put_env("AIUR_INSTANCE_KEY", "test-#{System.unique_integer([:positive])}")
    System.put_env("AIUR_GITHUB_BUDGET_DIR", sandbox_budget)
    Application.put_env(:aiur, :github_transport_test_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      restore_env("AIUR_DEV_TEST_TICKET_IDS", previous_scope)
      restore_env("AIUR_DEV_TEST_STATE_DIR", previous_state)
      restore_env("AIUR_INSTANCE_KEY", previous_instance)
      restore_env("AIUR_GITHUB_BUDGET_DIR", previous_budget)
      restore_application_env(:github_budget_dir, previous_app_budget)
      restore_application_env(:github_transport_test_options, previous_req_options)
      Aiur.TestCleanup.rm_rf!(sandbox_budget)
      Aiur.TestCleanup.rm_rf!(sandbox_state)
    end)

    :ok
  end

  test "rejects tracker and PR writes outside the sandbox ticket set" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.resp(conn, 200, "{}") end)

    assert {:error, {:outside_test_ticket_scope, "unknown"}} =
             Transport.default_request_fun(%{
               method: :post,
               url: "https://api.github.com/repos/#{tracker_repository()}/actions/runs/123/cancel",
               token: "token",
               body: %{}
             })

    assert {:error, {:outside_test_ticket_scope, "3379"}} =
             Transport.default_request_fun(%{
               method: :patch,
               url: tracker_issue_url(3379),
               token: "token",
               body: %{"labels" => ["agent:rework"]}
             })

    assert {:error, {:outside_test_ticket_scope, "unknown"}} =
             Transport.default_request_fun(%{
               method: :post,
               url: "https://api.github.com/repos/#{tracker_repository()}/pulls/3780/reviews",
               token: "token",
               body: %{"event" => "REQUEST_CHANGES"}
             })

    assert {:error, {:outside_test_ticket_scope, "unknown"}} =
             Transport.default_request_fun(%{
               method: :put,
               url: "https://api.github.com/repos/#{tracker_repository()}/pulls/99/merge",
               token: "token",
               body: %{"merge_method" => "squash"}
             })
  end

  test "allows GitHub App installation token exchange without tracker writes" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.resp(conn, 201, "{}") end)

    assert {:ok, %{status: 201}} =
             Transport.default_request_fun(%{
               method: :post,
               url: "https://api.github.com/app/installations/123/access_tokens",
               token: "jwt",
               body: %{}
             })
  end

  test "allows GraphQL reads but blocks GraphQL mutations in the sandbox" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:graphql_request_reached_http, conn.body_params["query"]})
      Plug.Conn.resp(conn, 200, "{}")
    end)

    assert {:ok, %{status: 200}} =
             Transport.default_request_fun(%{
               method: :post,
               url: "https://api.github.com/graphql",
               token: "token",
               body: %{"query" => "query Ticket { repository { issue(number: 99) { id } } }"}
             })

    assert_receive {:graphql_request_reached_http, "query Ticket { repository { issue(number: 99) { id } } }"}, 1_000

    assert {:error, {:outside_test_ticket_scope, "unknown"}} =
             Transport.default_request_fun(%{
               method: :post,
               url: "https://api.github.com/graphql",
               token: "token",
               body: %{"query" => "query Read { viewer { login } } mutation ChangeTicket { addLabelsToLabelable(input: {}) { clientMutationId } }"}
             })

    refute_receive {:graphql_request_reached_http, _query}, 50
  end

  test "rejects a pinned issue number on another repository or host" do
    other_repository = "someone-else/another-repo"

    for url <- [
          "https://api.github.com/repos/#{other_repository}/issues/99",
          "https://attacker.example/repos/#{tracker_repository()}/issues/99",
          "http://api.github.com/repos/#{tracker_repository()}/issues/99",
          "https://api.github.com:444/repos/#{tracker_repository()}/issues/99"
        ] do
      assert {:error, {:outside_test_ticket_scope, "unknown"}} =
               Aiur.TestTicketScope.with_write_scope(%{method: :patch, url: url}, fn -> :sent end)
    end

    assert {:error, {:outside_test_ticket_scope, "unknown"}} =
             Aiur.TestTicketScope.allow_write?(%{method: :patch, url: nil})
  end

  test "LandingWatch rework cannot write outside the sandbox tickets" do
    test_pid = self()
    server = {:global, {__MODULE__, make_ref()}}

    Req.Test.stub(__MODULE__, fn conn ->
      if conn.method in ["POST", "PATCH", "PUT", "DELETE"], do: send(test_pid, :out_of_scope_tracker_write_reached_http)

      Plug.Conn.resp(conn, 200, Jason.encode!(%{"state" => "open", "labels" => []}))
    end)

    observation = %{number: 12, head: "sha", rest: %{"head" => %{"ref" => "aiur/3379-test"}}}

    assert {:ok, pid} =
             Aiur.LandingWatch.start_link(
               name: server,
               interval_ms: 60_000,
               subscribe: false,
               observe_fun: fn _opts -> {:ok, [observation]} end,
               journal_prune_fun: fn _observations, _opts -> :ok end,
               process_fun: fn _observation, _opts ->
                 result =
                   Aiur.LandingWatch.rework(observation, [%{name: "failing check"}],
                     ticket_state_fun: fn "3379", _opts -> {:ok, "human-review"} end,
                     transition_fun: fn "3379", "rework", opts ->
                       assert opts[:writer] == :landing_watch

                       TicketTransition.write_state(
                         "3379",
                         "rework",
                         Keyword.put(opts, :tracker, TestTicketScopeTracker)
                       )
                     end,
                     alert_emitter: fn _topic, _opts -> :ok end
                   )

                 send(test_pid, {:landing_watch_result, result})
                 result
               end,
               queue_reconcile_fun: fn _observations, _opts -> :ok end
             )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert_receive {:landing_watch_result, {:error, {:outside_test_ticket_scope, "3379"}}}, 1_000
    assert landing_poll_finished?(server, 20)

    refute_receive :out_of_scope_tracker_write_reached_http, 50
  end

  test "allows writes to pinned sandbox tickets" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :sandbox_write_reached_http)
      Plug.Conn.resp(conn, 200, "{}")
    end)

    assert {:ok, %{status: 200}} =
             Transport.default_request_fun(%{
               method: :patch,
               url: tracker_issue_url(99),
               token: "token",
               body: %{"labels" => ["agent:rework"]}
             })

    assert_receive :sandbox_write_reached_http, 1000

    assert {:ok, %{status: 200}} =
             Transport.default_request_fun(%{
               method: :post,
               url: "https://api.github.com/repos/#{tracker_repository()}/issues/99/comments",
               token: "token",
               body: %{"body" => "test comment"}
             })

    assert_receive :sandbox_write_reached_http, 1_000
  end

  test "allows creating repository labels in the configured sandbox repository" do
    test_pid = self()
    expected_path = "/repos/#{tracker_repository()}/labels"

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:repository_label_create_reached_http, conn.request_path})
      Plug.Conn.resp(conn, 201, "{}")
    end)

    assert {:ok, %{status: 201}} =
             Transport.default_request_fun(%{
               method: :post,
               url: "https://api.github.com/repos/#{tracker_repository()}/labels",
               token: "token",
               body: %{"name" => "#{Config.label_prefix()}:queued"}
             })

    assert_receive {:repository_label_create_reached_http, ^expected_path}, 1_000

    assert {:error, {:outside_test_ticket_scope, "unknown"}} =
             Aiur.TestTicketScope.allow_write?(%{
               method: :post,
               url: "https://api.github.com/repos/#{tracker_repository()}/labels",
               body: %{"name" => "#{Config.label_prefix()}:unrelated"}
             })

    assert {:error, {:outside_test_ticket_scope, "unknown"}} =
             Aiur.TestTicketScope.allow_write?(%{
               method: :post,
               url: "https://api.github.com/repos/other/repository/labels",
               body: %{"name" => "#{Config.label_prefix()}:queued"}
             })
  end

  test "refuses dependency writes whose body can target another issue" do
    assert {:error, {:outside_test_ticket_scope, "99"}} =
             Aiur.TestTicketScope.with_write_scope(
               %{
                 method: :post,
                 url: "https://api.github.com/repos/#{tracker_repository()}/issues/99/dependencies/blocked_by",
                 body: %{"issue_id" => 123_456_789}
               },
               fn -> :sent end
             )
  end

  test "routes scoped budget state outside the live budget" do
    previous_budget = System.get_env("AIUR_GITHUB_BUDGET_DIR")
    live_budget = Path.join(System.tmp_dir!(), "live-budget-must-not-win")
    Application.put_env(:aiur, :github_budget_dir, live_budget)
    sandbox_dir = Path.join(System.tmp_dir!(), "aiur-test-budget-#{System.unique_integer([:positive])}")
    System.put_env("AIUR_GITHUB_BUDGET_DIR", sandbox_dir)

    assert Budget.state_dir() == sandbox_dir
    refute Budget.state_dir() == live_budget

    System.delete_env("AIUR_GITHUB_BUDGET_DIR")
    assert_raise ArgumentError, ~r/per-launch sandbox budget directory/, &Budget.state_dir/0

    restore_env("AIUR_GITHUB_BUDGET_DIR", previous_budget)
  end

  test "scoped budget requires the launch-provided unique directory" do
    previous_budget = System.get_env("AIUR_GITHUB_BUDGET_DIR")
    System.delete_env("AIUR_GITHUB_BUDGET_DIR")

    assert_raise ArgumentError, ~r/per-launch sandbox budget directory/, &Budget.state_dir/0

    restore_env("AIUR_GITHUB_BUDGET_DIR", previous_budget)
  end

  test "scoped Executor wakes and agent credentials use private sandbox paths" do
    previous_state = System.get_env("AIUR_DEV_TEST_STATE_DIR")
    previous_instance = System.get_env("AIUR_INSTANCE_KEY")
    previous_decision_dir = Application.get_env(:aiur, :decision_state_dir)
    previous_executor_state_dir = Application.get_env(:aiur, :executor_state_dir)
    previous_identity_source = Application.get_env(:aiur, :project_identity_source)
    state_dir = Path.join(System.tmp_dir!(), "aiur-test-state-test-#{System.unique_integer([:positive])}")
    System.put_env("AIUR_DEV_TEST_STATE_DIR", state_dir)
    System.put_env("AIUR_INSTANCE_KEY", "test-instance")
    Application.put_env(:aiur, :decision_state_dir, Path.join(System.tmp_dir!(), "shared-live-decision-state"))
    Application.put_env(:aiur, :executor_state_dir, Path.join(System.tmp_dir!(), "shared-live-executor-state"))
    Application.put_env(:aiur, :project_identity_source, TestTicketScopeProjectIdentity)

    assert StatePaths.dir() == Path.join(state_dir, "executor")
    assert Path.dirname(StatePaths.wakes_path()) == Path.join(state_dir, "executor")
    assert String.ends_with?(StatePaths.wakes_path(), ".executor.wakes.ndjson")
    assert AgentToken.path() == Path.join(Budget.state_dir(), "agent-token")
    assert {:ok, Path.join([state_dir, "test-instance", "aiur"])} == ConfigPaths.decision_state_dir()

    System.delete_env("AIUR_DEV_TEST_STATE_DIR")
    assert_raise ArgumentError, ~r/per-launch sandbox state directory/, &StatePaths.dir/0
    assert {:error, :missing_test_state_dir} == ConfigPaths.decision_state_dir()

    restore_env("AIUR_DEV_TEST_STATE_DIR", previous_state)
    restore_env("AIUR_INSTANCE_KEY", previous_instance)
    restore_application_env(:decision_state_dir, previous_decision_dir)
    restore_application_env(:executor_state_dir, previous_executor_state_dir)
    restore_application_env(:project_identity_source, previous_identity_source)
  end

  test "ordinary runs keep write access" do
    System.delete_env("AIUR_DEV_TEST_TICKET_IDS")

    assert Aiur.TestTicketScope.allow_write?(%{method: :patch, url: tracker_issue_url(3379)}) == :ok
  end

  test "unscoped write endpoints fail closed" do
    assert {:error, {:outside_test_ticket_scope, "unknown"}} =
             Aiur.TestTicketScope.allow_write?(%{method: :post, url: "https://api.github.com/repos/#{tracker_repository()}/issues"})

    assert {:error, {:outside_test_ticket_scope, "unknown"}} =
             Aiur.TestTicketScope.allow_write?(%{method: :post, url: "https://api.github.com/repos/#{tracker_repository()}/git/refs"})
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  defp tracker_repository, do: Config.repo()

  defp tracker_issue_url(number),
    do: "https://api.github.com/repos/#{tracker_repository()}/issues/#{number}"

  defp landing_poll_finished?(server, attempts) do
    state = Aiur.LandingWatch.state(server)

    cond do
      state.watcher == :unavailable and is_integer(state.last_poll_at_ms) ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        landing_poll_finished?(server, attempts - 1)
    end
  end
end

defmodule Aiur.GitHub.TestTicketScopeProjectIdentity do
  @moduledoc false

  def project_identity, do: "aiur-team/aiur"
end

defmodule Aiur.GitHub.TestTicketScopeTracker do
  @moduledoc false

  alias Aiur.GitHub.{Config, Transport}

  def update_issue_state(issue_id, state_name, _opts) do
    request = %{
      method: :patch,
      url: "https://api.github.com/repos/#{Config.repo()}/issues/#{issue_id}",
      token: "test-token",
      body: %{"state" => state_name}
    }

    Transport.default_request_fun(request)
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> other
    end
  end
end
