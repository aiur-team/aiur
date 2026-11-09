defmodule Aiur.CodingAgent.RouteFailureTest do
  use Aiur.TestSupport

  alias Aiur.CodingAgent.ProviderCredential
  alias Aiur.CodingAgent.RouteFailure
  alias Aiur.Issue
  alias Aiur.ModelAvailability

  test "local mode persists a provider auth hold after a 401" do
    path = Path.join(Aiur.TestSupport.tmp_root!("aiur-local-auth-hold"), "model-usage.json")
    previous_key = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "local-unused-api-key")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(Path.dirname(path)) end)
    on_exit(fn -> restore_env("ANTHROPIC_API_KEY", previous_key) end)

    assert Config.settings!().instance.mode == "local"
    assert :auth_rejected = RouteFailure.alert(%Issue{identifier: "LOCAL-401"}, "claude", :unauthorized, availability_opts: [path: path])
    assert ModelAvailability.auth_rejected?("claude", path: path)

    assert %{"auth_fingerprint" => "unavailable"} =
             ModelAvailability.load(path)["backends"]["claude"]
  end

  test "local mode does not fingerprint an exported key unused by profile auth" do
    assert ProviderCredential.fingerprint_for_mode("local", "claude", %{}, %{
             "CLAUDE_CODE_OAUTH_TOKEN" => "unused-exported-token",
             "ANTHROPIC_API_KEY" => "unused-api-key"
           }) == nil
  end
end
