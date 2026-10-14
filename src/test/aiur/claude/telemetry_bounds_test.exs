Code.require_file("telemetry_case.exs", __DIR__)

defmodule Aiur.Claude.TelemetryBoundsTest do
  use Aiur.Claude.TelemetryCase, async: false

  test "rejects duplicate accounting fields, oversized decimals, and malformed occurrence time", %{
    server: server,
    issue: issue
  } do
    launch = launch(server, issue)
    authorization = authorization(launch)

    compatible =
      payload("session-accounting-bounds", "request-accounting-bounds")
      |> append_record_attribute(%{"key" => "cost_usd", "value" => %{"doubleValue" => 0.125}})

    duplicate = append_record_attribute(compatible, attribute("input_tokens", 99))

    malformed_time =
      put_in(
        compatible,
        ["resourceLogs", Access.at(0), "scopeLogs", Access.at(0), "logRecords", Access.at(0), "timeUnixNano"],
        "not-a-timestamp"
      )

    encoded = Jason.encode!(compatible)
    oversized_decimal = String.replace(encoded, ~s("doubleValue":0.125), ~s("doubleValue":1e1000))

    refute oversized_decimal == encoded
    assert submit(server, authorization, duplicate).status == 400
    assert submit(server, authorization, malformed_time).status == 400
    assert submit(server, authorization, oversized_decimal).status == 413
    assert submit(server, authorization, compatible).status == 200
    assert Telemetry.health(server).accepted == 1
  end

  test "treats integer and string OTLP zero timestamps as unknown occurrence time", %{server: server, issue: issue} do
    assert :ok = Telemetry.subscribe_usage()

    for {zero, suffix} <- [{0, "integer"}, {"0", "string"}] do
      launch = launch(server, issue, backend: "claude-repl", attempt_id: "attempt-#{suffix}")

      compatible =
        payload("session-zero-#{suffix}", "request-zero-#{suffix}")
        |> append_record_attribute(attribute("cache_read_tokens", 3))
        |> append_record_attribute(attribute("cache_creation_tokens", 2))
        |> append_record_attribute(attribute("query_source", "repl_main_thread"))
        |> append_record_attribute(attribute("effort", "high"))
        |> append_record_attribute(%{"key" => "cost_usd", "value" => %{"doubleValue" => 0.125}})
        |> put_in(
          ["resourceLogs", Access.at(0), "scopeLogs", Access.at(0), "logRecords", Access.at(0), "timeUnixNano"],
          zero
        )

      assert submit(server, authorization(launch), compatible).status == 200
      assert_receive {:claude_usage, envelope}, 2_000
      assert envelope.occurred_at == nil
      refute inspect(envelope) =~ "1970-01-01"

      assert_receive {:claude_usage_coverage, %{class: :optional_field_absent, field: :occurred_at}},
                     2_000
    end
  end

  test "fails closed when the authenticated emitter version is absent or unsupported", %{server: server, issue: issue} do
    launch = launch(server, issue, backend: "claude-repl")
    authorization = authorization(launch)
    compatible = payload("session-versioned", "request-versioned")
    assert :ok = Telemetry.subscribe_usage()

    unsupported = replace_attribute(compatible, "service.version", %{"stringValue" => "2.1.211"})
    missing = drop_attribute(compatible, "service.version")

    assert submit(server, authorization, unsupported).status == 400

    assert_receive {:claude_usage_coverage, %{class: :unsupported_source_revision, field: :source_version} = unsupported_coverage},
                   2_000

    refute inspect(unsupported_coverage) =~ "2.1.211"

    assert submit(server, authorization, missing).status == 400

    assert_receive {:claude_usage_coverage, %{class: :unsupported_source_revision, field: :source_version}}, 2_000

    assert submit(server, authorization, compatible).status == 200

    assert Telemetry.health(server).rejections.unsupported_version == 2
  end

  test "rejects forbidden content in every accepted string field including the active capability", %{server: server, issue: issue} do
    launch = launch(server, issue)
    authorization = authorization(launch)
    capability = String.replace_prefix(authorization, "Bearer ", "")

    forbidden_values = [
      capability,
      authorization,
      "Authorization=#{authorization}",
      "owner@example.invalid",
      "/home/owner/private.txt",
      "free form event prose",
      "sk-123456789012345678901234567890"
    ]

    for key <- ~w(event.name session.id service.name service.version request_id model), value <- forbidden_values do
      rejected = replace_attribute(payload("session-content-free", "request-content-free"), key, %{"stringValue" => value})
      assert submit(server, authorization, rejected).status == 400
    end

    assert submit(server, authorization, payload("session-content-free", "request-content-free")).status == 200
    assert Telemetry.health(server).accepted == 1
  end

  test "enforces pinned per-field string grammars instead of a shared opaque-string rule", %{server: server, issue: issue} do
    launch = launch(server, issue)
    authorization = authorization(launch)
    compatible = payload("session-field-grammar", "request-field-grammar")

    invalid = [
      {"event.name", "api-error"},
      {"session.id", canonical_request_id("wrong-field")},
      {"request_id", canonical_session_id("wrong-field")},
      {"model", canonical_session_id("wrong-model")},
      {"model", "claude-secret-prompt"},
      {"service.name", "claude_code"},
      {"service.version", "claude-code-2.1.210"}
    ]

    for {key, value} <- invalid do
      rejected = replace_attribute(compatible, key, %{"stringValue" => value})
      assert submit(server, authorization, rejected).status == 400
    end

    assert submit(server, authorization, compatible).status == 200
  end

  test "authenticates before decoding and never logs an unauthenticated body", %{server: server, issue: issue} do
    launch = launch(server, issue)

    log =
      capture_log(fn ->
        response = submit(server, nil, "{malformed: TOP_SECRET}")
        assert response.status == 401
      end)

    refute log =~ "TOP_SECRET"
    assert submit(server, authorization(launch), payload("session-after-auth", "request-after-auth")).status == 200
    assert Telemetry.health(server).accepted == 1
  end

  test "accepts bounded batches and suppresses replay, session spoofing, and revoked producers", %{server: server, issue: issue} do
    launch = launch(server, issue)
    authorization = authorization(launch)
    batch = payload("session-current", ["request-one", "request-two"])

    assert submit(server, authorization, batch).status == 200
    assert Telemetry.health(server).accepted == 2
    assert submit(server, authorization, batch).status == 409
    assert submit(server, authorization, payload("session-spoof", "request-new")).status == 409

    assert :ok = Telemetry.revoke(launch, server)
    assert submit(server, authorization, payload("session-current", "request-after-revoke")).status == 401

    rejections = Telemetry.health(server).rejections
    assert rejections.replay == 1
    assert rejections.stale_session == 1
    assert rejections.unknown_capability == 1
  end

  test "bounds malformed input and attributes without crashing the receiver", %{server: server, issue: issue} do
    launch = launch(server, issue)
    authorization = authorization(launch)

    assert submit(server, authorization, "not-json").status == 400
    assert submit(server, authorization, oversized_payload()).status == 413
    assert submit(server, authorization, payload("session-current", "request-large", String.duplicate("a", 257))).status == 413

    rejections = Telemetry.health(server).rejections
    assert rejections.malformed == 1
    assert rejections.oversize == 1
    assert rejections.attribute_limit == 1
  end

  test "rejects malformed nested OTLP nodes without restarting the receiver", %{server: server, issue: issue} do
    launch = launch(server, issue)
    authorization = authorization(launch)
    compatible = payload("session-nested-node", "request-nested-node")
    receiver = Process.whereis(server)

    resource_null = put_in(compatible, ["resourceLogs", Access.at(0), "resource"], nil)
    scope_null = put_in(compatible, ["resourceLogs", Access.at(0), "scopeLogs", Access.at(0), "scope"], nil)

    assert submit(server, authorization, resource_null).status == 400
    assert submit(server, authorization, scope_null).status == 400
    assert Process.whereis(server) == receiver
    assert submit(server, authorization, compatible).status == 200
    assert Telemetry.health(server).rejections.malformed == 2
  end

  test "bounds OTLP integer strings before parsing and recovers on the next request", %{server: server, issue: issue} do
    launch = launch(server, issue)
    authorization = authorization(launch)
    compatible = payload("session-integer-bound", "request-integer-bound")

    oversized = replace_attribute(compatible, "event.sequence", %{"intValue" => String.duplicate("9", 20_000)})
    out_of_range = replace_attribute(compatible, "event.sequence", %{"intValue" => "9223372036854775808"})

    assert submit(server, authorization, oversized).status == 413
    assert submit(server, authorization, out_of_range).status == 413
    assert submit(server, authorization, compatible).status == 200
    assert Telemetry.health(server).accepted == 1
  end

  test "canonicalizes valid OTLP sequence encodings and rejects stringValue sequence identity", %{server: server, issue: issue} do
    launch = launch(server, issue)
    authorization = authorization(launch)

    encoded_string =
      payload("session-sequence", "request-sequence")
      |> drop_attribute("request_id")
      |> replace_attribute("event.sequence", %{"intValue" => "1"})

    encoded_number = replace_attribute(encoded_string, "event.sequence", %{"intValue" => 1})
    wrong_kind = replace_attribute(encoded_string, "event.sequence", %{"stringValue" => "2"})
    recovered = replace_attribute(encoded_string, "event.sequence", %{"intValue" => "2"})

    assert submit(server, authorization, encoded_string).status == 200
    assert submit(server, authorization, encoded_number).status == 409
    assert submit(server, authorization, wrong_kind).status == 400
    assert submit(server, authorization, recovered).status == 200
    assert Telemetry.health(server).accepted == 2
  end

  @tag max_events_per_window: 2
  test "bounds concurrent requests and reserves rate capacity before body decoding", %{server: server, issue: issue} do
    first = launch(server, issue)
    first_authorization = authorization(first)

    assert {:ok, held_request} = Telemetry.authorize(first_authorization, server)
    assert {:error, :concurrent_limit} = Telemetry.authorize(first_authorization, server)
    assert :ok = Telemetry.release_request(held_request, server)

    second = launch(server, issue)
    second_authorization = authorization(second)

    assert submit(server, second_authorization, payload("session-current", ["request-one", "request-two"])).status == 200
    assert submit(server, second_authorization, "not-json").status == 429

    rejections = Telemetry.health(server).rejections
    assert rejections.concurrent_limit == 1
    assert rejections.rate_limited == 1
    refute Map.has_key?(rejections, :malformed)
  end

  test "a partial loopback client times out without taking down the receiver", %{server: server, issue: issue} do
    launch = launch(server, issue)
    authorization = authorization(launch)
    %URI{port: port} = URI.parse(endpoint(launch))

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    request = [
      "POST /v1/logs HTTP/1.1\r\n",
      "Host: 127.0.0.1\r\n",
      "Content-Type: application/json\r\n",
      "Authorization: ",
      authorization,
      "\r\nContent-Length: 8\r\n\r\n{"
    ]

    assert :ok = :gen_tcp.send(socket, request)
    assert {:ok, "HTTP/1.1 408" <> _response} = :gen_tcp.recv(socket, 0, 2_000)
    assert :ok = :gen_tcp.close(socket)

    assert submit(server, authorization, payload("session-recovered", "request-recovered")).status == 200
  end

  test "the listener applies its connection bound once across the receiver", %{server: server} do
    listener = :sys.get_state(server).listener

    acceptor_pool =
      listener
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {:acceptor_pool_supervisor, pid, :supervisor, _modules} -> pid
        _child -> nil
      end)

    assert is_pid(acceptor_pool)
    assert length(Supervisor.which_children(acceptor_pool)) == 1
  end
end
