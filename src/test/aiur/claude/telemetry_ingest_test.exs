Code.require_file("telemetry_case.exs", __DIR__)

defmodule Aiur.Claude.TelemetryIngestTest do
  use Aiur.Claude.TelemetryCase, async: false
  @fixture Path.expand("../../fixtures/claude/telemetry-2.1.210-api-request.json", __DIR__)
  @model "claude-sonnet-4-6"

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

    refute_receive {:claude_usage_coverage, _coverage}, 100
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
    refute_receive {:claude_usage, _envelope}, 100
    refute_receive {:claude_usage_coverage, _coverage}, 100

    repl = launch(server, issue, backend: "claude-repl")
    authorization = authorization(repl)
    accepted = File.read!(@fixture)

    assert submit(server, authorization, accepted).status == 200
    assert_receive {:claude_usage, first}, 2_000
    assert first.attribution.tracker_identity == issue.tracker_identity

    assert submit(server, authorization, accepted).status == 409
    assert submit(server, authorization, payload("session-stale", "request-stale")).status == 409
    refute_receive {:claude_usage, _envelope}, 100
    refute_receive {:claude_usage_coverage, _coverage}, 100

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
    refute_receive {:claude_usage, _envelope}, 100
    refute_receive {:claude_usage_coverage, _coverage}, 100

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
    refute_receive {:claude_usage, _envelope}, 100
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
end
