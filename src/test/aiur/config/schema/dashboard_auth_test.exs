defmodule Aiur.Config.Schema.DashboardAuthTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  test "dashboard sign-in defaults preserve Basic Auth and disable optional methods" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.dashboard_auth.browser_basic_auth
    refute settings.dashboard_auth.passkeys
    assert settings.dashboard_auth.session_max_age_days == 30
    assert settings.dashboard_auth.google.allowed_emails == []
  end

  test "valid allowlisted Google login and passkey settings parse together" do
    config = %{
      "server" => %{"public_url" => "https://aiur.example.ts.net:4001"},
      "dashboard_auth" => %{
        "google" => %{"allowed_emails" => ["operator@gmail.com"]},
        "passkeys" => true,
        "session_max_age_days" => 14,
        "browser_basic_auth" => false
      }
    }

    assert {:ok, settings} = Schema.parse(config)
    assert settings.dashboard_auth.google.allowed_emails == ["operator@gmail.com"]
    assert settings.dashboard_auth.passkeys
    refute settings.dashboard_auth.browser_basic_auth
    assert settings.dashboard_auth.session_max_age_days == 14
  end

  test "invalid email allowlists and session ages are rejected" do
    assert {:error, {:invalid_workflow_config, email_error}} =
             Schema.parse(%{"dashboard_auth" => %{"google" => %{"allowed_emails" => ["operator"]}}})

    assert email_error =~ "allowed_emails"

    assert {:error, {:invalid_workflow_config, age_error}} =
             Schema.parse(%{"dashboard_auth" => %{"session_max_age_days" => 366}})

    assert age_error =~ "session_max_age_days"
  end
end
