defmodule Aiur.GitHub.TransportQuotaTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{Budget, Quota, Transport}

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)
    previous_options = Application.get_env(:aiur, :github_transport_test_options)
    previous_quota = Application.get_env(:aiur, :github_quota_server)
    previous_budget_enabled = Application.get_env(:aiur, :github_budget_enabled?)
    previous_budget_dir = Application.get_env(:aiur, :github_budget_dir)
    previous_budget_settings = Application.get_env(:aiur, :github_budget_settings_override)
    quota = start_supervised!({Quota, name: nil, emit_fun: fn _name, _opts -> :ok end})
    budget_dir = Path.join(System.tmp_dir!(), "aiur-transport-budget-#{System.unique_integer([:positive])}")

    Application.put_env(:aiur, :github_transport_test_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:aiur, :github_quota_server, quota)
    Application.put_env(:aiur, :github_budget_enabled?, false)

    on_exit(fn ->
      restore_env(:github_transport_test_options, previous_options)
      restore_env(:github_quota_server, previous_quota)
      restore_env(:github_budget_enabled?, previous_budget_enabled)
      restore_env(:github_budget_dir, previous_budget_dir)
      restore_env(:github_budget_settings_override, previous_budget_settings)
      File.rm_rf(budget_dir)
    end)

    {:ok, quota: quota, budget_dir: budget_dir}
  end

  test "records the authoritative budget and ticket attribution from a response", %{quota: quota} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-resource", "core")
      |> Plug.Conn.put_resp_header("x-ratelimit-limit", "5000")
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "4100")
      |> Plug.Conn.put_resp_header("x-ratelimit-reset", Integer.to_string(System.os_time(:second) + 3600))
      |> Req.Test.json(%{"number" => 1670})
    end)

    assert {:ok, %{status: 200}} =
             Transport.default_request_fun(%{
               method: :get,
               url: "https://api.github.com/repos/owner/repo/issues/1670",
               token: "token"
             })

    snapshot = Quota.snapshot(quota)
    assert snapshot.windows["core"].remaining == 4100
    assert [%{consumer: "ticket:1670", reads: 1, writes: 0, total: 1, cost: 1, costs: %{"core" => 1}}] = snapshot.attribution
  end

  test "returns a local rate-limit response without sending another exhausted request", %{quota: quota} do
    reset_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    Quota.observe(
      quota,
      %{method: :get, url: "https://api.github.com/repos/owner/repo/issues", token: "token"},
      {:ok,
       %{
         status: 403,
         headers: [
           {"x-ratelimit-resource", "core"},
           {"x-ratelimit-limit", "5000"},
           {"x-ratelimit-remaining", "0"},
           {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(reset_at))}
         ],
         body: %{"message" => "rate limit exceeded"}
       }}
    )

    _snapshot = Quota.snapshot(quota)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :request_sent)
      Req.Test.json(conn, [])
    end)

    assert {:ok, response} =
             Transport.default_request_fun(%{
               method: :get,
               url: "https://api.github.com/repos/owner/repo/issues",
               token: "token"
             })

    assert response.status == 429
    assert Transport.header(response.headers, "x-ratelimit-remaining") == "0"
    refute_receive :request_sent
  end

  test "records GraphQL quota and mutation attribution", %{quota: quota} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-resource", "graphql")
      |> Plug.Conn.put_resp_header("x-ratelimit-limit", "5000")
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "3999")
      |> Plug.Conn.put_resp_header("x-ratelimit-reset", Integer.to_string(System.os_time(:second) + 3600))
      |> Req.Test.json(%{"data" => %{"addLabelsToLabelable" => %{"clientMutationId" => nil}}})
    end)

    assert {:ok, %{status: 200}} =
             Transport.default_request_fun(%{
               method: :post,
               url: Transport.graphql_url(),
               token: "token",
               body: %{
                 "query" => "mutation AddLabels($number: Int!) { addLabelsToLabelable(input: {}) { clientMutationId } }",
                 "variables" => %{"number" => 1670}
               }
             })

    snapshot = Quota.snapshot(quota)
    assert snapshot.windows["graphql"].remaining == 3999
    assert [%{consumer: "ticket:1670", reads: 0, writes: 1, total: 1, cost: 1, costs: %{"graphql" => 1}}] = snapshot.attribution
  end

  test "blocks exhausted GraphQL without an outbound request", %{quota: quota} do
    reset_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    Quota.observe(
      quota,
      %{method: :post, url: Transport.graphql_url(), token: "token", body: %{"query" => "query { viewer { login } }"}},
      {:ok,
       %{
         status: 403,
         headers: [
           {"x-ratelimit-resource", "graphql"},
           {"x-ratelimit-limit", "5000"},
           {"x-ratelimit-remaining", "0"},
           {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(reset_at))}
         ],
         body: %{"message" => "rate limit exceeded"}
       }}
    )

    _snapshot = Quota.snapshot(quota)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :graphql_request_sent)
      Req.Test.json(conn, %{})
    end)

    assert {:ok, %{status: 429} = response} =
             Transport.default_request_fun(%{
               method: :post,
               url: Transport.graphql_url(),
               token: "token",
               body: %{"query" => "query { viewer { login } }"}
             })

    assert Transport.header(response.headers, "x-ratelimit-resource") == "graphql"
    refute_receive :graphql_request_sent
  end

  test "holds a second daemon-shaped request behind the shared host lease", %{budget_dir: budget_dir} do
    Application.put_env(:aiur, :github_budget_enabled?, true)
    Application.put_env(:aiur, :github_budget_dir, budget_dir)

    Application.put_env(:aiur, :github_budget_settings_override, %{
      max_inflight: 1,
      max_inflight_per_endpoint: 1,
      requests_per_minute: 20,
      stagger_ms: 0
    })

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_started, self()})

      receive do
        :release_request -> Req.Test.json(conn, [])
      end
    end)

    request = fn ->
      Transport.default_request_fun(%{
        method: :get,
        url: "https://api.github.com/repos/owner/repo/issues/1477",
        token: "shared-token"
      })
    end

    first = Task.async(request)
    assert_receive {:request_started, first_conn}, 2_000

    second = Task.async(request)
    refute_receive {:request_started, _second_conn}, 80

    send(first_conn, :release_request)
    assert_receive {:request_started, second_conn}, 2_000
    send(second_conn, :release_request)

    assert {:ok, %{status: 200}} = Task.await(first, 1_500)
    assert {:ok, %{status: 200}} = Task.await(second, 1_500)
  end

  test "does not hide a secondary-limit response behind a retry", %{budget_dir: budget_dir} do
    Application.put_env(:aiur, :github_budget_enabled?, true)
    Application.put_env(:aiur, :github_budget_dir, budget_dir)

    Application.put_env(:aiur, :github_budget_settings_override, %{
      max_inflight: 4,
      max_inflight_per_endpoint: 2,
      requests_per_minute: 20,
      stagger_ms: 0
    })

    attempts = :counters.new(1, [:write_concurrency])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(attempts, 1, 1)

      case :counters.get(attempts, 1) do
        1 ->
          conn
          |> Plug.Conn.put_status(429)
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Req.Test.json(%{"message" => "You have exceeded a secondary rate limit"})

        _ ->
          Req.Test.json(conn, %{"number" => 1477})
      end
    end)

    request = %{
      method: :get,
      url: "https://api.github.com/repos/owner/repo/issues/1477",
      token: "shared-token"
    }

    assert {:ok, %{status: 429}} = Transport.default_request_fun(request)
    assert :counters.get(attempts, 1) == 1

    assert {:hold, %{reason: :shared_budget}} =
             Budget.acquire(
               %{request | url: "https://api.github.com/repos/owner/repo/pulls/1477"},
               timeout_ms: 10
             )
  end

  test "does not send a request when configured broker state is unavailable", %{budget_dir: budget_dir} do
    File.mkdir_p!(budget_dir)
    blocked_dir = Path.join(budget_dir, "blocked")
    File.write!(blocked_dir, "not a directory")
    Application.put_env(:aiur, :github_budget_enabled?, true)
    Application.put_env(:aiur, :github_budget_dir, blocked_dir)

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :request_sent)
      Req.Test.json(conn, [])
    end)

    assert {:ok, %{status: 429}} =
             Transport.default_request_fun(%{
               method: :get,
               url: "https://api.github.com/repos/owner/repo/issues/1477",
               token: "shared-token"
             })

    refute_receive :request_sent
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
