defmodule Aiur.BuildOrder.BoundedTest do
  use Aiur.TestSupport

  alias Aiur.BuildOrder.Bounded
  alias Aiur.TrackerIdentity

  test "accepts only bounded same-origin relative routes" do
    assert Bounded.relative_route("/chat/42?tab=logs#current") ==
             {:ok, "/chat/42?tab=logs#current"}

    for unsafe <- [
          "//evil.example/path",
          "/\\evil.example/path",
          "/\nevil.example/path",
          "/\tevil.example/path",
          <<"/", 255>>,
          "/" <> String.duplicate("a", 2_048),
          "https://evil.example/path",
          ""
        ] do
      assert Bounded.relative_route(unsafe) == :error
    end
  end

  test "accepts only the exact query-free Chat route for one issue identity" do
    identity = identity(42)

    assert Bounded.chat_route_for("/chat/42", identity) == {:ok, "/chat/42"}

    for unsafe <- [
          "/chat/41",
          "/chat/42?capability=private",
          "/chat/42#token=private",
          "/chat/42/extra",
          "/commands/42"
        ] do
      assert Bounded.chat_route_for(unsafe, identity) == :error
    end
  end

  test "accepts only query-free canonical Commands detail routes" do
    assert Bounded.commands_route("/commands/42") == {:ok, "/commands/42"}
    assert Bounded.commands_route("/commands/dec%20%2F42") == {:ok, "/commands/dec%20%2F42"}
    assert Bounded.commands_route("/decisions/42") == {:ok, "/decisions/42"}

    token = "ghp_" <> String.duplicate("a", 36)

    for unsafe <- [
          "/commands",
          "/commands/42?token=private",
          "/commands/42#capability=private",
          "/commands/42/extra",
          "/commands//42",
          "/commands/42/",
          "/commands/%0A42",
          "/commands/%20leading",
          "/commands/..",
          "/commands/%2E%2E",
          "/commands/#{token}"
        ] do
      assert Bounded.commands_route(unsafe) == :error
    end
  end

  defp identity(number) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "ISSUE-#{number}",
      identifier: to_string(number)
    }
  end
end
