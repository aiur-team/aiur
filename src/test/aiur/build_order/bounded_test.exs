defmodule Aiur.BuildOrder.BoundedTest do
  use Aiur.TestSupport

  alias Aiur.BuildOrder.Bounded

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
end
