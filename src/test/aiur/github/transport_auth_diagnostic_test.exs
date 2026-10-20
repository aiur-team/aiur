defmodule Aiur.GitHub.TransportAuthDiagnosticTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.GitHub.{AppTokenRefresher, Config, Credential, Transport}
  alias Aiur.GitHub.Transport.AuthDiagnostic

  @cache_key {Config, :resolved_token}
  @app_token_key {AppTokenRefresher, :installation_token}
  @transport_test_options_key :github_transport_test_options
  @selector_options_key :github_credential_selector_options

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_cached_token = :persistent_term.get(@cache_key, :unset)
    previous_options = Application.get_env(:aiur, @transport_test_options_key)
    previous_selector_options = Application.get_env(:aiur, @selector_options_key)
    :persistent_term.erase(@cache_key)
    System.put_env("GITHUB_TOKEN", "config-token")
    Application.put_env(:aiur, @transport_test_options_key, plug: {Req.Test, __MODULE__})

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)

      case previous_cached_token do
        :unset -> :persistent_term.erase(@cache_key)
        token -> :persistent_term.put(@cache_key, token)
      end

      case previous_options do
        nil -> Application.delete_env(:aiur, @transport_test_options_key)
        options -> Application.put_env(:aiur, @transport_test_options_key, options)
      end

      restore_application_env(@selector_options_key, previous_selector_options)
    end)

    :ok
  end

  test "a watcher 401 reports the applied credential and logs a token fingerprint without retrying" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      send(test_pid, {:authorization, authorization})
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
    end)

    token = "config-token-#{System.unique_integer([:positive])}"
    System.put_env("GITHUB_TOKEN", token)
    :persistent_term.put(@cache_key, token)

    log =
      capture_log(fn ->
        assert {:ok, %{status: 401, credential: "github_token"}} =
                 Transport.default_request_fun(%{
                   method: :get,
                   url: "https://api.github.com/repos/owner/repo/commits",
                   caller: "main_watch_commits",
                   token: token
                 })
      end)

    assert_received {:authorization, "Bearer " <> authorization_token}
    assert authorization_token == token
    refute_received {:authorization, "Bearer readiness-token"}
    assert log =~ "method=GET host=api.github.com path=/repos/owner/repo/commits"
    assert log =~ "credential_id=primary credential_class=github_token"
    assert log =~ "auth_bytes=#{byte_size(token)}"
    refute log =~ token
  end

  test "an unresolved token does not imply a non-primary quota identity" do
    Application.put_env(:aiur, @selector_options_key, credentials: [])

    request = %{
      method: :get,
      url: "https://api.github.com/rate_limit",
      caller: "ci_readiness",
      token: "readiness-token"
    }

    assert result = AuthDiagnostic.run(request, & &1)
    refute Map.has_key?(result, :credential_id)
  end

  test "401 class follows the selected credential when the configured source is env" do
    previous_app_token = :persistent_term.get(@app_token_key, :unset)
    app_token = "ghs-selected-app-token"
    AppTokenRefresher.cache_token(app_token, DateTime.add(DateTime.utc_now(), 3600), %{})
    primary = %Credential{id: "primary", kind: :machine_user, token_env: "GITHUB_TOKEN", primary?: true, writes?: true}
    app = %Credential{id: "selected-app", kind: :app_installation, writes?: true}

    Application.put_env(:aiur, @selector_options_key,
      credentials: [primary, app],
      windows: %{Credential.identity_key(primary) => %{"core" => %{remaining: 0, reset_at: DateTime.add(DateTime.utc_now(), 600)}}}
    )

    on_exit(fn ->
      case previous_app_token do
        :unset -> AppTokenRefresher.clear_token()
        cached -> :persistent_term.put(@app_token_key, cached)
      end
    end)

    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      send(parent, {:selected_authorization, authorization})
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
    end)

    assert Config.token_source() == :env

    assert {:ok, %{status: 401, credential: "github_app_installation"}} =
             Transport.default_request_fun(%{
               method: :get,
               url: "https://api.github.com/repos/owner/repo/commits",
               caller: "main_watch_commits",
               token: "config-token"
             })

    assert_received {:selected_authorization, "Bearer " <> actual_token}
    assert actual_token == app_token
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)
end
