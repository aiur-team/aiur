defmodule Aiur.GitHub.CredentialClassTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{AppTokenRefresher, Credential, CredentialSelector}

  test "labels the selected App installation credential instead of its configured source" do
    key = {AppTokenRefresher, :installation_token}
    previous = :persistent_term.get(key, :unset)
    token = "ghs_test_installation_token"

    AppTokenRefresher.cache_token(token, DateTime.add(DateTime.utc_now(), 3600), %{})

    on_exit(fn ->
      case previous do
        :unset -> AppTokenRefresher.clear_token()
        cached -> :persistent_term.put(key, cached)
      end
    end)

    app = %Credential{id: "app", kind: :app_installation}

    assert %{credential_class: "github_app_installation"} =
             CredentialSelector.assign(
               %{method: :get, url: "https://api.github.com/repos/o/r", token: token},
               credentials: [app]
             )
  end
end
