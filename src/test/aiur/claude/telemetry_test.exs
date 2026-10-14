Code.require_file("telemetry_case.exs", __DIR__)

defmodule Aiur.Claude.TelemetryTest do
  use Aiur.Claude.TelemetryCase, async: false

  @deterministic_capability Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)

  test "replacement rotates the capability and explicit teardown revokes the generation", %{server: server, issue: issue} do
    first = launch(server, issue)
    second = launch(server, issue)

    assert submit(server, authorization(first), payload("session-first", "request-first")).status == 401
    assert submit(server, authorization(second), payload("session-second", "request-second")).status == 200

    assert :ok = Telemetry.revoke(second, server)
    assert Telemetry.health(server).active_generations == 0
  end

  test "releasing an in-flight request after teardown cannot restore its capability", %{server: server, issue: issue} do
    first = launch(server, issue)
    authorization = authorization(first)

    assert {:ok, request_id} = Telemetry.authorize(authorization, server)
    assert :ok = Telemetry.revoke(first, server)
    assert :ok = Telemetry.release_request(request_id, server)
    assert Telemetry.health(server).active_generations == 0

    second = launch(server, issue)
    assert submit(server, authorization, payload("session-stale", "request-stale")).status == 401
    assert submit(server, authorization(second), payload("session-current", "request-current")).status == 200
  end

  test "launch configuration uses a loopback HTTP/JSON logs-only transport with explicit content gates", %{server: server, issue: issue} do
    launch = launch(server, issue)
    env = Map.new(launch.env)

    assert env["CLAUDE_CODE_ENABLE_TELEMETRY"] == "1"
    assert env["OTEL_LOGS_EXPORTER"] == "otlp"
    assert env["OTEL_METRICS_EXPORTER"] == "none"
    assert env["OTEL_TRACES_EXPORTER"] == "none"
    assert env["OTEL_EXPORTER_OTLP_LOGS_PROTOCOL"] == "http/json"
    assert String.starts_with?(env["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"], "http://127.0.0.1:")

    for key <- ~w(OTEL_LOG_USER_PROMPTS OTEL_LOG_ASSISTANT_RESPONSES OTEL_LOG_TOOL_DETAILS OTEL_LOG_TOOL_CONTENT OTEL_LOG_RAW_API_BODIES) do
      assert env[key] == "0"
    end
  end

  test "status inspection redacts capability-bearing state", %{server: server, issue: issue} do
    launch = launch(server, issue)
    capability = authorization(launch)

    refute inspect(:sys.get_status(server)) =~ capability
    refute Map.has_key?(Telemetry.health(server), :endpoint)
  end

  test "an unavailable receiver fails the launch without crashing its owner", %{issue: issue} do
    missing_server = Module.concat(__MODULE__, :MissingReceiver)

    assert {:error, :receiver_unavailable} =
             Telemetry.prepare_launch(issue,
               server: missing_server,
               attempt_id: "attempt-1",
               workspace_ownership: %{generation: 7},
               backend: "claude"
             )
  end

  @tag capability_mint: :deterministic
  test "capability minting is injectable and never replaces a live generation", %{server: server, issue: issue} do
    assert %{env: env} = launch(server, issue)

    assert {"OTEL_EXPORTER_OTLP_LOGS_HEADERS", "Authorization=Bearer " <> @deterministic_capability} =
             List.keyfind(env, "OTEL_EXPORTER_OTLP_LOGS_HEADERS", 0)

    assert {:error, :capability_unavailable} =
             Telemetry.prepare_launch(issue,
               server: server,
               attempt_id: "attempt-2",
               workspace_ownership: %{generation: 8},
               backend: "claude"
             )

    assert Telemetry.health(server).rejections.capability_unavailable == 1
  end
end
