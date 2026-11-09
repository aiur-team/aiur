defmodule AiurWeb.DashboardAuthControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AiurWeb.DashboardAuth.{ChallengeStore, Passkeys}
  alias AiurWeb.{DashboardAuthController, FinancialDataAccess}

  @session_options Plug.Session.init(store: :cookie, key: "_aiur_auth_test", signing_salt: "aiur-auth-test")

  setup do
    previous_workflow_override = Process.get(:workflow_file_path_override)
    previous_endpoint = Application.get_env(:aiur, AiurWeb.Endpoint)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    config_dir = Aiur.TestSupport.tmp_root!("dashboard-auth-controller")
    File.mkdir_p!(config_dir)
    config_path = Path.join(config_dir, "config")
    :ok = Aiur.TestSupport.write_workflow_file!(config_path)
    original = File.read!(config_path)

    config =
      if String.contains?(original, "\nserver:\n") do
        String.replace(original, "\nserver:\n", "\nserver:\n  public_url: https://aiur.example.test:4001\n", global: false)
      else
        original <> "\nserver:\n  public_url: https://aiur.example.test:4001\n"
      end

    File.write!(config_path, config <> "\ndashboard_auth:\n  passkeys: true\n  google:\n    allowed_emails: [operator@example.test]\n")
    Process.put(:workflow_file_path_override, config_path)
    Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.put(previous_endpoint || [], :secret_key_base, String.duplicate("s", 64)))
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    on_exit(fn ->
      if previous_workflow_override do
        Process.put(:workflow_file_path_override, previous_workflow_override)
      else
        Process.delete(:workflow_file_path_override)
      end

      if previous_endpoint do
        Application.put_env(:aiur, AiurWeb.Endpoint, previous_endpoint)
      else
        Application.delete_env(:aiur, AiurWeb.Endpoint)
      end

      Aiur.TestSupport.restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      Aiur.TestSupport.restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)

      Aiur.TestCleanup.rm_rf!(config_dir)
      FinancialDataAccess.Generation.invalidate()
    end)

    :ok
  end

  test "passkey enrollment challenge refuses a session without recent Google authentication" do
    conn = DashboardAuthController.registration_challenge(session_conn(), %{})

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "fresh Google sign-in required"}
    assert get_session(conn, :passkey_registration_challenge) == nil
  end

  test "passkey enrollment finish refuses a challenge after Google authentication expires" do
    challenge = Wax.new_registration_challenge(origin: "https://aiur.example.test:4001", rp_id: "aiur.example.test", user_verification: "required")
    assert {:ok, challenge_id} = Passkeys.put_challenge(challenge, {127, 0, 0, 1})

    conn =
      session_conn()
      |> put_session(:google_authenticated_at, System.system_time(:second) - 301)
      |> put_session(:google_email, "operator@example.test")
      |> put_session(:passkey_registration_challenge, challenge_id)

    response =
      DashboardAuthController.registration_finish(conn, %{
        "credential" => %{"response" => %{"attestationObject" => "AA", "clientDataJSON" => "AA"}}
      })

    assert response.status == 422
    assert {:ok, ^challenge} = Passkeys.take_challenge(challenge_id)
  end

  test "unauthenticated logout leaves the shared session generation unchanged" do
    configure_credentials_for_logout_test()
    assert {:ok, marker} = FinancialDataAccess.new_browser_session_marker()
    authenticated = put_session(session_conn(), FinancialDataAccess.session_key(), marker)
    assert {:ok, context} = FinancialDataAccess.context_from_session(%{FinancialDataAccess.session_key() => marker})
    assert {:ok, generation_before} = FinancialDataAccess.identity(context)

    response = DashboardAuthController.logout(session_conn(), %{})

    assert response.status == 302
    assert {:ok, ^generation_before} = FinancialDataAccess.identity(context)
    assert get_session(authenticated, FinancialDataAccess.session_key()) == marker
  end

  test "verified email outside the configured allowlist is refused without a marker" do
    user = %{"email" => "intruder@example.test", "email_verified" => true}
    conn = DashboardAuthController.complete_google_sign_in(session_conn(), user)

    assert conn.status == 401
    assert get_session(conn, FinancialDataAccess.session_key()) == nil
  end

  test "Google callback rejects mismatched state without a session marker" do
    conn =
      session_conn()
      |> put_session(:google_session_params, %{state: "expected-state", nonce: "expected-nonce"})
      |> DashboardAuthController.google_callback(%{"state" => "attacker-state", "code" => "unused"})

    assert conn.status == 401
    assert get_session(conn, FinancialDataAccess.session_key()) == nil
  end

  test "authentication finish consumes its challenge before refusing a replay" do
    assert Passkeys.enabled?()
    challenge = Wax.new_authentication_challenge(origin: "https://aiur.example.test:4001", rp_id: "aiur.example.test")
    assert {:ok, challenge_id} = ChallengeStore.put(challenge)
    conn = put_session(session_conn(), :passkey_authentication_challenge, challenge_id)

    first = DashboardAuthController.authentication_finish(conn, %{"assertion" => %{"rawId" => "invalid"}})
    replay_conn = put_session(session_conn(), :passkey_authentication_challenge, challenge_id)
    replay = DashboardAuthController.authentication_finish(replay_conn, %{"assertion" => %{"rawId" => "invalid"}})

    assert first.status == 401
    assert replay.status == 401
    assert {:error, :challenge_missing_or_replayed} = Passkeys.take_challenge(challenge_id)
    assert get_session(replay, FinancialDataAccess.session_key()) == nil
  end

  defp session_conn do
    :post
    |> conn("/auth")
    |> Map.put(:secret_key_base, String.duplicate("s", 64))
    |> Plug.Session.call(@session_options)
    |> fetch_session()
  end

  defp configure_credentials_for_logout_test do
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")
    endpoint = Application.get_env(:aiur, AiurWeb.Endpoint, [])
    Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.put(endpoint, :dashboard_auth_required, true))
  end
end
