defmodule Aiur.CodingAgent.RouteFailureTest do
  use Aiur.TestSupport

  alias Aiur.CodingAgent.RouteFailure
  alias Aiur.Issue
  alias Aiur.ModelAvailability

  test "local mode persists a provider auth hold after a 401" do
    path = Path.join(Aiur.TestSupport.tmp_root!("aiur-local-auth-hold"), "model-usage.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(Path.dirname(path)) end)

    assert :auth_rejected = RouteFailure.alert(%Issue{identifier: "LOCAL-401"}, "claude", :unauthorized, availability_opts: [path: path])
    assert ModelAvailability.auth_rejected?("claude", path: path)
  end
end
