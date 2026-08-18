defmodule Aiur.GitHub.AppTokenRefresherTest do
  # async: false — these tests start a named GenServer and mutate env + cache.
  use ExUnit.Case, async: false

  alias Aiur.GitHub.AppTokenRefresher

  @app_id "12345"
  @installation_id "67890"

  defp pem do
    {_map, pem} = JOSE.JWK.to_pem(JOSE.JWK.generate_key({:rsa, 2048}))
    pem
  end

  defp put_app_credentials do
    System.put_env("GITHUB_APP_ID", @app_id)
    System.put_env("GITHUB_APP_INSTALLATION_ID", @installation_id)
    System.put_env("GITHUB_APP_PRIVATE_KEY", pem())
  end

  defp clear_app_credentials do
    System.delete_env("GITHUB_APP_ID")
    System.delete_env("GITHUB_APP_INSTALLATION_ID")
    System.delete_env("GITHUB_APP_PRIVATE_KEY")
    System.delete_env("GITHUB_APP_PRIVATE_KEY_PATH")
  end

  defp install_test_env(test_pid) do
    previous_token = System.get_env("GITHUB_TOKEN")

    clear_app_credentials()
    AppTokenRefresher.clear_token()
    System.delete_env("GITHUB_TOKEN")

    emit_fun = fn topic, message, opts ->
      send(test_pid, {:alert, topic, message, opts})
    end

    on_exit(fn ->
      AppTokenRefresher.clear_token()

      case previous_token do
        nil -> System.delete_env("GITHUB_TOKEN")
        value -> System.put_env("GITHUB_TOKEN", value)
      end

      clear_app_credentials()
    end)

    emit_fun
  end

  defp unique_name, do: :"app_token_refresher_test_#{System.unique_integer([:positive])}"

  describe "start_link/1" do
    test "acquires and caches the installation token when the cache is empty" do
      test_pid = self()
      emit_fun = install_test_env(test_pid)
      put_app_credentials()

      request_fun = fn
        %{method: :post, url: _url} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "token" => "ghs_installation_token_ok",
               "expires_at" => "2026-08-03T12:00:00Z",
               "permissions" => %{"contents" => "write", "issues" => "write", "pull_requests" => "write", "metadata" => "read"}
             }
           }}

        %{method: :get, url: "https://api.github.com/rate_limit"} ->
          {:ok, %{status: 200, headers: %{"x-ratelimit-remaining" => ["42"]}, body: %{}}}
      end

      name = unique_name()
      {:ok, pid} = AppTokenRefresher.start_link(name: name, request_fun: request_fun, emit_fun: emit_fun)
      on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

      assert AppTokenRefresher.current_token() == "ghs_installation_token_ok"

      # A healthy acquisition raises no token-lifecycle alert. The separate
      # startup identity check (`system.github_app_token.identity_mismatch`,
      # covered in AppIdentityTest) depends on the ambient workflow config
      # rather than this acquisition, so it is not what this test pins.
      refute_received {:alert, "system.github_app_token.refresh_failed", _, _}
      refute_received {:alert, "system.github_app_token.permission_violation", _, _}
    end

    test "is inert when no App credentials are configured" do
      test_pid = self()
      emit_fun = install_test_env(test_pid)

      name = unique_name()

      {:ok, pid} =
        AppTokenRefresher.start_link(
          name: name,
          request_fun: fn _ -> flunk("no request should fire without App credentials") end,
          emit_fun: emit_fun
        )

      on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

      assert AppTokenRefresher.current_token() == nil
      refute_received {:alert, _, _, _}

      # Even a stray refresh message is ignored: a disabled refresher never
      # acquires, retries, or alerts.
      send(pid, :refresh)
      Process.sleep(50)
      refute_received {:alert, _, _, _}
    end
  end

  describe "refresh failure" do
    test "emits a needs-attention alert, keeps the last good token, and leaks no secret" do
      test_pid = self()
      emit_fun = install_test_env(test_pid)
      put_app_credentials()

      # Simulate a successful boot-time acquisition the refresher then inherits.
      AppTokenRefresher.cache_token("ghs_installation_token_good", DateTime.from_iso8601("2026-08-03T12:00:00Z") |> elem(1), %{"contents" => "write"})

      request_fun = fn
        %{method: :post, url: _url} ->
          {:ok, %{status: 500, body: %{"message" => "boom"}}}

        %{method: :get, url: "https://api.github.com/rate_limit"} ->
          {:ok, %{status: 200, headers: %{"x-ratelimit-remaining" => ["42"]}, body: %{}}}
      end

      name = unique_name()
      {:ok, pid} = AppTokenRefresher.start_link(name: name, request_fun: request_fun, emit_fun: emit_fun)
      on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

      # The cache is populated, so init only schedules; drive one refresh deterministically.
      send(pid, :refresh)

      assert_receive {:alert, "system.github_app_token.refresh_failed", message, opts}, 2_000
      assert opts[:needs_attention] == true
      assert message =~ "refresh failed"
      refute message =~ "ghs_installation_token_good"
      assert message =~ "HTTP 500"

      # The last known-good token is still served despite the failed refresh.
      assert AppTokenRefresher.current_token() == "ghs_installation_token_good"
    end

    test "does not re-alert on a consecutive failure within the same episode" do
      test_pid = self()
      emit_fun = install_test_env(test_pid)
      put_app_credentials()

      AppTokenRefresher.cache_token("ghs_installation_token_good", DateTime.from_iso8601("2026-08-03T12:00:00Z") |> elem(1), %{"contents" => "write"})

      request_fun = fn
        %{method: :post, url: _url} -> {:ok, %{status: 500, body: %{}}}
        %{method: :get, url: "https://api.github.com/rate_limit"} -> {:ok, %{status: 200, headers: %{"x-ratelimit-remaining" => ["42"]}, body: %{}}}
      end

      name = unique_name()
      {:ok, pid} = AppTokenRefresher.start_link(name: name, request_fun: request_fun, emit_fun: emit_fun)
      on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

      send(pid, :refresh)
      assert_receive {:alert, "system.github_app_token.refresh_failed", _, _}, 2_000

      send(pid, :refresh)
      refute_received {:alert, "system.github_app_token.refresh_failed", _, _}
    end
  end

  describe "permission verification" do
    test "emits a needs-attention alert when the granted set exceeds least privilege" do
      test_pid = self()
      emit_fun = install_test_env(test_pid)
      put_app_credentials()

      request_fun = fn
        %{method: :post, url: _url} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "token" => "ghs_installation_token_overgranted",
               "expires_at" => "2026-08-03T12:00:00Z",
               "permissions" => %{"contents" => "write", "administration" => "write"}
             }
           }}

        %{method: :get, url: "https://api.github.com/rate_limit"} ->
          {:ok, %{status: 200, headers: %{"x-ratelimit-remaining" => ["42"]}, body: %{}}}
      end

      name = unique_name()
      {:ok, pid} = AppTokenRefresher.start_link(name: name, request_fun: request_fun, emit_fun: emit_fun)
      on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

      assert_receive {:alert, "system.github_app_token.permission_violation", message, opts}, 2_000
      assert opts[:needs_attention] == true
      assert message =~ "administration"
    end
  end

  describe "recovery" do
    test "reports recovery and re-arms alerting after a failure is cleared" do
      test_pid = self()
      emit_fun = install_test_env(test_pid)
      put_app_credentials()

      {:ok, exchange_counter} = Agent.start_link(fn -> 0 end)

      request_fun = fn
        %{method: :post, url: _url} ->
          attempt = Agent.get_and_update(exchange_counter, fn n -> {n, n + 1} end)

          if attempt == 0 do
            {:ok, %{status: 500, body: %{}}}
          else
            {:ok,
             %{
               status: 200,
               body: %{
                 "token" => "ghs_installation_token_recovered",
                 "expires_at" => "2026-08-03T12:00:00Z",
                 "permissions" => %{"contents" => "write", "issues" => "write", "pull_requests" => "write", "metadata" => "read"}
               }
             }}
          end

        %{method: :get, url: "https://api.github.com/rate_limit"} ->
          {:ok, %{status: 200, headers: %{"x-ratelimit-remaining" => ["42"]}, body: %{}}}
      end

      name = unique_name()
      {:ok, pid} = AppTokenRefresher.start_link(name: name, request_fun: request_fun, emit_fun: emit_fun)
      on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

      # init acquire fails -> one needs-attention alert.
      assert_receive {:alert, "system.github_app_token.refresh_failed", _, opts}, 2_000
      assert opts[:needs_attention] == true

      # A forced refresh now succeeds: recovery alert + token cached + alert re-armed.
      send(pid, :refresh)
      assert_receive {:alert, "system.github_app_token.refresh_recovered", _, _}, 2_000
      assert AppTokenRefresher.current_token() == "ghs_installation_token_recovered"

      # The successful refresh re-armed alerting: another forced refresh (still
      # succeeding) must NOT re-alert — proving the failure episode stayed closed.
      send(pid, :refresh)
      refute_received {:alert, "system.github_app_token.refresh_failed", _, _}
    end
  end
end
