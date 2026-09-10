defmodule Aiur.Claude.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Aiur.Claude.{Telemetry, Telemetry.Receiver, Telemetry.UsageAdapter}
  alias Aiur.{Issue, TrackerIdentity, UsageEnvelope}

  @deterministic_capability Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)
  @fixture Path.expand("../../fixtures/claude/telemetry-2.1.210-api-request.json", __DIR__)
  @model "claude-sonnet-4-6"

  setup context do
    name = Module.concat(__MODULE__, :"Receiver#{System.unique_integer([:positive, :monotonic])}")

    options =
      [
        name: name,
        max_inflight: 1,
        max_events_per_window: context[:max_events_per_window] || 120,
        replay_capacity: 4
      ]
      |> maybe_put_capability_fun(context[:capability_mint])

    start_supervised!({Telemetry, options})

    {:ok, tracker_identity} =
      TrackerIdentity.from_github(
        %{"node_id" => "I_kwDOTelemetry", "number" => 1123},
        {"its-everdred", "aiur"},
        {"its-everdred", "aiur"}
      )

    %{server: name, issue: %Issue{identifier: "1123", tracker_identity: tracker_identity}}
  end

  test "delivers only the allowlisted api-request shape with trusted current correlation", %{server: server, issue: issue} do
    launch = launch(server, issue)
    assert :ok = Telemetry.subscribe()

    response = submit(server, authorization(launch), payload("session-current", "request-current", "TOP_SECRET"))
    assert response.status == 200

    assert_receive {:claude_telemetry, event}, 2_000
    assert event.event == :api_request
    assert event.source_version == Telemetry.source_version()
    assert event.transport == :otlp_http_json
    assert event.identity == {:request, canonical_request_id("request-current")}
    assert event.correlation.ticket == issue.tracker_identity
    assert event.correlation.attempt_id == "attempt-1"
    assert event.correlation.worker_generation == 7
    assert event.correlation.backend == "claude"
    assert event.correlation.session_id == canonical_session_id("session-current")

    assert event.attributes == %{
             "event.sequence" => 1,
             "input_tokens" => 11,
             "model" => @model,
             "output_tokens" => 7,
             "request_id" => canonical_request_id("request-current")
           }

    refute inspect(event) =~ "TOP_SECRET"
  end

  test "reports the model the running agent actually served, once per change", %{server: server, issue: issue} do
    # A `claude` route names no version, so the dashboard can only say which
    # model is running if the session reports it. Every api-request event
    # carries it; re-reporting an unchanged model would be pure noise.
    issue = %{issue | id: "issue-1123"}
    launch = launch(server, issue, execution_recipient: self())

    assert submit(server, authorization(launch), payload("session-observed", "request-first")).status == 200
    assert_receive {:session_resolved_model, "issue-1123", @model}, 2_000

    assert submit(server, authorization(launch), payload("session-observed", "request-second")).status == 200
    refute_receive {:session_resolved_model, _issue_id, _model}, 200
  end

  test "names no model for a launch with no execution recipient", %{server: server, issue: issue} do
    launch = launch(server, issue)

    assert submit(server, authorization(launch), payload("session-anonymous", "request-anonymous")).status == 200
    refute_receive {:session_resolved_model, _issue_id, _model}, 200
  end

  test "accepts the sanitized exact Claude Code 2.1.210 compatibility fixture", %{server: server, issue: issue} do
    launch = launch(server, issue)
    assert :ok = Telemetry.subscribe()

    fixture = File.read!(@fixture)
    assert submit(server, authorization(launch), fixture).status == 200

    assert_receive {:claude_telemetry, event}, 2_000
    assert event.source_version == "claude-code-2.1.210"
    assert event.identity == {:request, "req_011111111111111111111111"}
    assert event.correlation.session_id == "11111111-1111-4111-8111-111111111111"
    assert event.occurred_at == ~U[2026-07-16 23:00:00.000000Z]
    assert %Decimal{} = event.attributes["cost_usd"]
    assert Decimal.equal?(event.attributes["cost_usd"], Decimal.new("0.0001234567890123456789"))

    assert Map.delete(event.attributes, "cost_usd") == %{
             "cache_creation_tokens" => 13,
             "cache_read_tokens" => 89,
             "effort" => "high",
             "event.sequence" => 17,
             "input_tokens" => 101,
             "model" => "claude-sonnet-4-6",
             "output_tokens" => 23,
             "query_source" => "repl_main_thread",
             "request_id" => "req_011111111111111111111111"
           }

    refute inspect(event) =~ "removed@example.invalid"
    refute inspect(event) =~ "removed-org"
  end

  test "publishes exact request usage only after authenticated repl correlation", %{server: server, issue: issue} do
    launch = launch(server, issue, backend: "claude-repl")
    assert :ok = Telemetry.subscribe_usage()

    assert submit(server, authorization(launch), File.read!(@fixture)).status == 200
    assert_receive {:claude_usage, envelope}, 2_000

    assert envelope.attribution.run_id == Aiur.Boot.run_id()
    assert envelope.attribution.tracker_identity == issue.tracker_identity
    assert envelope.attribution.attempt_id == "attempt-1"
    assert envelope.attribution.session_id == "11111111-1111-4111-8111-111111111111"
    assert envelope.backend == :remote_control
    assert envelope.transport == :otlp
    assert envelope.query_source == "repl_main_thread"
    assert Decimal.equal?(envelope.cost.amount, Decimal.new("0.0001234567890123456789"))

    assert {:ok, %{canonical_total: 226, input_total: 203, output_total: 23, coverage: :full}} =
             UsageEnvelope.reconcile(envelope, UsageAdapter.relationship_catalog())

    refute_receive {:claude_usage_coverage, _coverage}
  end

  test "accounts for bounded subagent request sources without publishing the agent name", %{server: server, issue: issue} do
    launch = launch(server, issue, backend: "claude-repl")
    assert :ok = Telemetry.subscribe()
    assert :ok = Telemetry.subscribe_usage()

    subagent =
      payload("session-subagent", "request-subagent")
      |> append_record_attribute(attribute("query_source", "code-reviewer"))

    assert submit(server, authorization(launch), subagent).status == 200
    assert_receive {:claude_telemetry, event}, 2_000
    assert_receive {:claude_usage, envelope}, 2_000
    assert event.attributes["query_source"] == "subagent"
    assert envelope.query_source == "subagent"
    refute inspect(event) =~ "code-reviewer"
    refute inspect(envelope) =~ "code-reviewer"
  end

  test "publishes bounded optional coverage without fabricating cache or cost", %{server: server, issue: issue} do
    launch = launch(server, issue, backend: "claude-repl")
    assert :ok = Telemetry.subscribe_usage()

    assert submit(server, authorization(launch), payload("session-partial", "request-partial")).status == 200
    assert_receive {:claude_usage, envelope}, 2_000

    assert envelope.update_kind == :partial
    assert envelope.cost == nil
    assert envelope.tokens.cached_input == nil
    assert envelope.tokens.cache_creation_input == nil
    refute envelope.tokens.cached_input == 0
    refute envelope.tokens.cache_creation_input == 0

    coverage =
      for _ <- 1..6 do
        assert_receive {:claude_usage_coverage, coverage}, 2_000
        coverage
      end

    assert Enum.map(coverage, & &1.field) == [
             :cache_read_tokens,
             :cache_creation_tokens,
             :query_source,
             :effort,
             :cost_usd,
             :occurred_at
           ]

    assert Enum.all?(coverage, &(&1.class == :optional_field_absent))
  end

  test "never turns headless, replayed, stale-session, or cross-ticket input into the wrong envelope", %{
    server: server,
    issue: issue
  } do
    assert :ok = Telemetry.subscribe_usage()

    headless = launch(server, issue)
    assert submit(server, authorization(headless), payload("session-headless", "request-headless")).status == 200
    refute_receive {:claude_usage, _envelope}
    refute_receive {:claude_usage_coverage, _coverage}

    repl = launch(server, issue, backend: "claude-repl")
    authorization = authorization(repl)
    accepted = File.read!(@fixture)

    assert submit(server, authorization, accepted).status == 200
    assert_receive {:claude_usage, first}, 2_000
    assert first.attribution.tracker_identity == issue.tracker_identity

    assert submit(server, authorization, accepted).status == 409
    assert submit(server, authorization, payload("session-stale", "request-stale")).status == 409
    refute_receive {:claude_usage, _envelope}
    refute_receive {:claude_usage_coverage, _coverage}

    other_issue = issue("1124")
    other = launch(server, other_issue, backend: "claude-repl", attempt_id: "attempt-2", workspace_ownership: %{generation: 8})

    assert submit(server, authorization(other), payload("session-other", "request-other")).status == 200
    assert_receive {:claude_usage, second}, 2_000
    assert second.attribution.tracker_identity == other_issue.tracker_identity
    refute second.idempotency_key == first.idempotency_key
    refute second.counter_epoch == first.counter_epoch
  end

  test "unsupported and disallowed local surfaces cannot create or alter accounting", %{server: server, issue: issue} do
    launch = launch(server, issue, backend: "claude-repl")
    authorization = authorization(launch)
    assert :ok = Telemetry.subscribe_usage()

    unsupported =
      put_in(payload("session-hook", "request-hook"), ["resourceLogs", Access.at(0), "scopeLogs", Access.at(0), "logRecords", Access.at(0), "body"], %{"stringValue" => "claude_code.hook_turn"})

    assert submit(server, authorization, unsupported).status == 400
    refute_receive {:claude_usage, _envelope}
    refute_receive {:claude_usage_coverage, _coverage}

    disallowed =
      [
        attribute("hook_turn", "PROMPT_SECRET"),
        attribute("transcript", "TRANSCRIPT_SECRET"),
        attribute("display_tailer", "DISPLAY_SECRET"),
        attribute("status_line", "STATUS_SECRET"),
        attribute("browser_state", "BROWSER_SECRET")
      ]
      |> Enum.reduce(payload("session-safe", "request-safe"), &append_record_attribute(&2, &1))

    assert submit(server, authorization, disallowed).status == 200
    assert_receive {:claude_usage, envelope}, 2_000
    assert envelope.tokens.input == 11
    assert envelope.tokens.output == 7
    refute inspect(envelope) =~ "SECRET"
  end

  test "keeps optional request accounting fields absent instead of fabricating values", %{server: server, issue: issue} do
    launch = launch(server, issue)
    assert :ok = Telemetry.subscribe()

    assert submit(server, authorization(launch), payload("session-optional", "request-optional")).status == 200
    assert_receive {:claude_telemetry, event}, 2_000

    assert event.occurred_at == nil
    refute Map.has_key?(event.attributes, "cost_usd")
    refute Map.has_key?(event.attributes, "query_source")
    refute Map.has_key?(event.attributes, "effort")
    refute Map.has_key?(event.attributes, "cache_read_tokens")
    refute Map.has_key?(event.attributes, "cache_creation_tokens")
  end

  test "publishes terminal coverage for authenticated identity and measurement failures", %{server: server, issue: issue} do
    launch = launch(server, issue, backend: "claude-repl")
    authorization = authorization(launch)
    assert :ok = Telemetry.subscribe_usage()

    missing_session = drop_attribute(payload("session-missing", "request-missing-session"), "session.id")
    missing_input = drop_attribute(payload("session-missing", "request-missing-input"), "input_tokens")

    assert submit(server, authorization, missing_session).status == 400

    assert_receive {:claude_usage_coverage, %{class: :missing_required_identity, field: :session_id} = identity_coverage},
                   2_000

    refute inspect(identity_coverage) =~ "request-missing-session"

    assert submit(server, authorization, missing_input).status == 400

    assert_receive {:claude_usage_coverage, %{class: :ambiguous_measurement_semantics, field: :input_tokens} = measurement_coverage},
                   2_000

    refute inspect(measurement_coverage) =~ "request-missing-input"
    refute_receive {:claude_usage, _envelope}
  end

  test "rejects unreviewed accounting strings and inexact cost before publication", %{server: server, issue: issue} do
    launch = launch(server, issue)
    authorization = authorization(launch)

    compatible =
      payload("session-accounting-grammar", "request-accounting-grammar")
      |> append_record_attribute(attribute("query_source", "repl_main_thread"))
      |> append_record_attribute(attribute("effort", "xhigh"))
      |> append_record_attribute(%{"key" => "cost_usd", "value" => %{"doubleValue" => 0.125}})

    for {key, value} <- [{"query_source", "owner@example.invalid"}, {"query_source", "unreviewed_agent"}, {"effort", "extreme"}] do
      rejected = replace_attribute(compatible, key, %{"stringValue" => value})
      assert submit(server, authorization, rejected).status == 400
    end

    inexact = replace_attribute(compatible, "cost_usd", %{"doubleValue" => "0.125"})
    negative = replace_attribute(compatible, "cost_usd", %{"doubleValue" => -0.125})

    assert submit(server, authorization, inexact).status == 400
    assert submit(server, authorization, negative).status == 400
    assert submit(server, authorization, compatible).status == 200
  end

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

  defp launch(server, issue, opts \\ []) do
    assert {:ok, launch} =
             Telemetry.prepare_launch(
               issue,
               Keyword.merge(
                 [server: server, attempt_id: "attempt-1", workspace_ownership: %{generation: 7}, backend: "claude"],
                 opts
               )
             )

    launch
  end

  defp issue(identifier) do
    number = String.to_integer(identifier)

    {:ok, tracker_identity} =
      TrackerIdentity.from_github(
        %{"node_id" => "I_kwDOTelemetry#{identifier}", "number" => number},
        {"its-everdred", "aiur"},
        {"its-everdred", "aiur"}
      )

    %Issue{identifier: identifier, tracker_identity: tracker_identity}
  end

  defp authorization(%{env: env}) do
    {_, authorization} = Enum.find(env, fn {key, _value} -> key == "OTEL_EXPORTER_OTLP_LOGS_HEADERS" end)
    String.replace_prefix(authorization, "Authorization=", "")
  end

  defp endpoint(%{env: env}) do
    env
    |> Map.new()
    |> Map.fetch!("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")
  end

  defp submit(server, authorization, body) when is_map(body), do: submit(server, authorization, Jason.encode!(body))

  defp submit(server, authorization, body) do
    conn =
      conn(:post, "/v1/logs", body)
      |> put_req_header("content-type", "application/json")
      |> maybe_put_authorization(authorization)

    Receiver.call(conn, registry: server)
  end

  defp maybe_put_authorization(conn, nil), do: conn
  defp maybe_put_authorization(conn, authorization), do: put_req_header(conn, "authorization", authorization)

  defp payload(session_id, request_ids, extra_attribute \\ "")

  defp payload(session_id, request_ids, extra_attribute) when is_list(request_ids) do
    %{
      "resourceLogs" => [
        %{
          "resource" => %{
            "attributes" => [
              attribute("service.name", "claude-code"),
              attribute("service.version", "2.1.210"),
              attribute("session.id", canonical_session_id(session_id))
            ]
          },
          "scopeLogs" => [%{"scope" => %{"attributes" => []}, "logRecords" => Enum.map(request_ids, &record(&1, extra_attribute))}]
        }
      ]
    }
  end

  defp payload(session_id, request_id, extra_attribute), do: payload(session_id, [request_id], extra_attribute)

  defp record(request_id, extra_attribute) do
    attributes =
      [
        attribute("event.name", "api_request"),
        attribute("request_id", canonical_request_id(request_id)),
        attribute("model", @model),
        attribute("event.sequence", 1),
        attribute("input_tokens", 11),
        attribute("output_tokens", 7)
      ] ++
        if(extra_attribute == "", do: [], else: [attribute("unrelated.attribute", extra_attribute)])

    %{"body" => %{"stringValue" => "claude_code.api_request"}, "attributes" => attributes}
  end

  defp attribute(key, value) when is_binary(value), do: %{"key" => key, "value" => %{"stringValue" => value}}
  defp attribute(key, value) when is_integer(value), do: %{"key" => key, "value" => %{"intValue" => value}}

  defp oversized_payload do
    %{"resourceLogs" => String.duplicate("x", 32_769)}
  end

  defp replace_attribute(value, key, replacement) when is_list(value),
    do: Enum.map(value, &replace_attribute(&1, key, replacement))

  defp replace_attribute(%{"key" => key} = attribute, key, replacement),
    do: Map.put(attribute, "value", replacement)

  defp replace_attribute(value, key, replacement) when is_map(value),
    do: Map.new(value, fn {map_key, map_value} -> {map_key, replace_attribute(map_value, key, replacement)} end)

  defp replace_attribute(value, _key, _replacement), do: value

  defp append_record_attribute(value, attribute) when is_map(value) do
    update_in(value, ["resourceLogs", Access.at(0), "scopeLogs", Access.at(0), "logRecords", Access.at(0), "attributes"], &(&1 ++ [attribute]))
  end

  defp drop_attribute(value, key) when is_list(value) do
    value
    |> Enum.reject(&match?(%{"key" => ^key}, &1))
    |> Enum.map(&drop_attribute(&1, key))
  end

  defp drop_attribute(value, key) when is_map(value),
    do: Map.new(value, fn {map_key, map_value} -> {map_key, drop_attribute(map_value, key)} end)

  defp drop_attribute(value, _key), do: value

  defp canonical_session_id(label) do
    digest = :sha256 |> :crypto.hash(label) |> Base.encode16(case: :lower)
    a = String.slice(digest, 0, 8)
    b = String.slice(digest, 8, 4)
    c = String.slice(digest, 13, 3)
    d = String.slice(digest, 17, 3)
    e = String.slice(digest, 20, 12)

    "#{a}-#{b}-4#{c}-8#{d}-#{e}"
  end

  defp canonical_request_id(label) do
    suffix = :sha256 |> :crypto.hash(label) |> Base.encode16() |> binary_part(0, 24)
    "req_#{suffix}"
  end

  defp maybe_put_capability_fun(opts, :deterministic), do: Keyword.put(opts, :capability_fun, fn -> @deterministic_capability end)
  defp maybe_put_capability_fun(opts, _mint), do: opts
end
