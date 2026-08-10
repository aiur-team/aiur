defmodule Aiur.GitHub.TransportQuotaTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{Quota, Transport}

  setup do
    {:ok, _started} = Application.ensure_all_started(:req)
    previous_options = Application.get_env(:aiur, :github_transport_test_options)
    previous_quota = Application.get_env(:aiur, :github_quota_server)
    quota = start_supervised!({Quota, name: nil, emit_fun: fn _name, _opts -> :ok end})

    Application.put_env(:aiur, :github_transport_test_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:aiur, :github_quota_server, quota)

    on_exit(fn ->
      restore_env(:github_transport_test_options, previous_options)
      restore_env(:github_quota_server, previous_quota)
    end)

    {:ok, quota: quota}
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
    assert snapshot.attribution == [%{consumer: "ticket:1670", reads: 1, writes: 0, total: 1}]
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
    assert snapshot.attribution == [%{consumer: "ticket:1670", reads: 0, writes: 1, total: 1}]
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

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
end
