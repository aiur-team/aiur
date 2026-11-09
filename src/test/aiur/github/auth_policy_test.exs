defmodule Aiur.GitHub.AuthPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.AuthPolicy

  test "hosted auth rejects a PAT without the explicit opt-in" do
    settings = %{instance: %{mode: "hosted"}}
    env = %{"GITHUB_TOKEN" => "pat-secret"}

    assert {:error, message} = AuthPolicy.auth_policy_error(settings, env)
    assert message =~ "AIUR_GITHUB_ALLOW_PAT=1"
    refute message =~ "pat-secret"
  end

  test "hosted startup rejects the PAT before resolving a credential" do
    settings = %{instance: %{mode: "hosted"}}
    env = %{"GITHUB_TOKEN" => "pat-secret"}

    assert {:error, message} =
             AuthPolicy.validate_tracker(settings, env, fn -> flunk("PAT must be rejected before token lookup") end, fn ->
               flunk("PAT must be rejected before repository lookup")
             end)

    assert message =~ "AIUR_GITHUB_ALLOW_PAT=1"
  end

  test "hosted startup permits an explicitly opted-in PAT" do
    settings = %{instance: %{mode: "hosted"}}
    env = %{"GITHUB_TOKEN" => "pat-secret", "AIUR_GITHUB_ALLOW_PAT" => "1"}

    assert AuthPolicy.validate_tracker(settings, env, fn -> "pat-secret" end, fn -> "owner/repo" end) == :ok
  end

  test "regression guard: a complete App credential group permits a configured PAT" do
    settings = %{instance: %{mode: "hosted"}}

    env = %{
      "GITHUB_TOKEN" => "pat-secret",
      "GITHUB_APP_ID" => "123",
      "GITHUB_APP_INSTALLATION_ID" => "456",
      "GITHUB_APP_PRIVATE_KEY" => "private-key-content"
    }

    assert AuthPolicy.auth_policy_error(settings, env) == :ok
  end
end
