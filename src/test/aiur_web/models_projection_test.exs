defmodule AiurWeb.ModelsProjectionTest do
  use ExUnit.Case, async: true

  alias AiurWeb.ModelsProjection

  test "configured route order preserves priority and adds complexity routing overrides" do
    routes = ModelsProjection.ordered_routes(["codex:gpt-5.5:high", "claude:sonnet"], %{3 => ["openrouter:anthropic/sonnet", "claude:sonnet"]})
    assert routes == ["codex:gpt-5.5:high", "claude:sonnet", "openrouter:anthropic/sonnet"]
  end

  test "a route without observed meter or ledger usage remains unknown" do
    route = ModelsProjection.route_for("codex:gpt-5.5:high", 0, ["codex:gpt-5.5:high"], %{}, %{"backends" => %{}}, DateTime.utc_now())
    assert route.usage.state == "unknown"
    assert Enum.all?(route.usage.windows, &is_nil(&1.used_percent))
  end
end
