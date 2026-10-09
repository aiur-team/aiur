defmodule AiurWeb.CapabilityErrorTest do
  use ExUnit.Case, async: false
  import Plug.Test

  test "degraded dependency returns 409 with the typed envelope and current identity" do
    response = AiurWeb.CapabilityError.render(conn(:post, "/write"), %{id: "commands.answer", state: :degraded, reason: :dependency_unavailable, depends_on: ["orchestration"]})
    assert response.status == 409

    assert Jason.decode!(response.resp_body) == %{
             "error" => "capability_unavailable",
             "capability" => "commands.answer",
             "state" => "degraded",
             "reason" => "dependency_unavailable",
             "depends_on" => ["orchestration"],
             "revision" => Aiur.Capabilities.report([]).revision,
             "boot_id" => Aiur.Boot.run_id()
           }
  end

  test "not_running returns 503 and preserves the cause with null dependencies" do
    response = AiurWeb.CapabilityError.render(conn(:post, "/write"), %{id: "orchestration", state: :unavailable, reason: :not_running})
    assert response.status == 503
    body = Jason.decode!(response.resp_body)
    assert body["reason"] == "not_running"
    assert body["state"] == "unavailable"
    assert body["depends_on"] == nil
  end
end
