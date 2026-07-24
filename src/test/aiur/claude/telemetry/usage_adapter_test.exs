defmodule Aiur.Claude.Telemetry.UsageAdapterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.Claude.Telemetry.UsageAdapter
  alias Aiur.{TrackerIdentity, UsageEnvelope}
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @ingested_at ~U[2026-07-16 23:00:02Z]

  test "maps the pinned request event into an exact additive envelope" do
    assert {:ok, envelope, []} = UsageAdapter.normalize(event(), @ingested_at)

    assert envelope.provider == :claude
    assert envelope.source == "claude_code.api_request"
    assert envelope.source_version == "claude-code-2.1.210"
    assert envelope.source_event_id == "req_011111111111111111111111"
    assert envelope.source_sequence == 17
    assert envelope.occurred_at == ~U[2026-07-16 23:00:00Z]
    assert envelope.measurement_kind == :delta
    assert envelope.counter_scope == :request
    assert envelope.update_kind == :full
    assert envelope.backend == :remote_control
    assert envelope.transport == :otlp
    assert envelope.auth_mode == :unknown
    assert envelope.query_source == "repl_main_thread"
    assert envelope.effort == "high"
    assert envelope.requested_model == nil
    assert envelope.resolved_model == "claude-sonnet-4-6"
    assert envelope.context_tier == :not_applicable
    assert envelope.cache_write_duration == :five_minutes
    assert envelope.attribution.run_id == "run-1116"
    assert envelope.attribution.tracker_identity == tracker_identity()
    assert envelope.attribution.attempt_id == "attempt-1"
    assert envelope.attribution.session_id == "11111111-1111-4111-8111-111111111111"
    assert envelope.attribution.request_id == "req_011111111111111111111111"
    assert envelope.account_generation.generation == nil
    assert envelope.account_generation.reason == :untrusted_lifecycle

    assert envelope.tokens == %{
             input: 100,
             cached_input: 30,
             cache_creation_input: 20,
             output: 10,
             reasoning_output: nil,
             provider_reported_total: nil
           }

    assert Decimal.equal?(envelope.cost.amount, Decimal.new("0.0001234567890123456789"))
    assert envelope.cost.currency == "USD"
    assert envelope.cost.measurement_kind == :delta
    assert envelope.cost.counter_scope == :request
    assert envelope.cost.source == "claude_code.api_request.cost_usd"

    assert {:ok, %{canonical_total: 160, input_total: 150, output_total: 10, status: :derived, coverage: :full}} =
             UsageEnvelope.reconcile(envelope, UsageAdapter.relationship_catalog())
  end

  test "keeps retry identity stable and rotates it with authenticated generations" do
    source = event()
    assert {:ok, first, []} = UsageAdapter.normalize(source, @ingested_at)
    assert {:ok, retry, []} = UsageAdapter.normalize(source, @ingested_at)
    assert first.idempotency_key == retry.idempotency_key
    assert first.counter_epoch == retry.counter_epoch

    resumed = put_in(source, [:attributes, "event.sequence"], 18)
    assert {:ok, resumed, []} = UsageAdapter.normalize(resumed, @ingested_at)
    assert first.idempotency_key == resumed.idempotency_key
    assert first.source_sequence != resumed.source_sequence

    replacement =
      source
      |> put_in([:correlation, :attempt_id], "attempt-2")
      |> put_in([:correlation, :worker_generation], 8)
      |> put_in([:correlation, :producer_generation], "producer-2")

    assert {:ok, replacement, []} = UsageAdapter.normalize(replacement, @ingested_at)
    refute first.idempotency_key == replacement.idempotency_key
    refute first.counter_epoch == replacement.counter_epoch

    other_run = put_in(source, [:correlation, :run_id], "run-1117")
    assert {:ok, other_run, []} = UsageAdapter.normalize(other_run, @ingested_at)
    refute first.idempotency_key == other_run.idempotency_key
    refute first.counter_epoch == other_run.counter_epoch
  end

  test "uses the session-scoped sequence when the optional request id is absent" do
    source =
      event()
      |> put_in([:identity], {:sequence, 17})
      |> update_in([:attributes], &Map.delete(&1, "request_id"))

    assert {:ok, envelope, coverage} = UsageAdapter.normalize(source, @ingested_at)
    assert envelope.source_event_id == "event.sequence:17"
    assert envelope.attribution.request_id == nil
    assert Enum.map(coverage, & &1.field) == [:request_id]
  end

  test "preserves missing optionals as partial coverage instead of zero" do
    source =
      event()
      |> Map.put(:occurred_at, nil)
      |> put_in([:identity], {:sequence, 17})
      |> update_in([:attributes], fn attributes ->
        Map.drop(attributes, ~w(request_id cache_read_tokens cache_creation_tokens query_source effort cost_usd))
      end)

    assert {:ok, envelope, coverage} = UsageAdapter.normalize(source, @ingested_at)

    assert envelope.update_kind == :partial
    assert envelope.occurred_at == nil
    assert envelope.cost == nil
    assert envelope.query_source == nil
    assert envelope.effort == nil
    assert envelope.tokens.cached_input == nil
    assert envelope.tokens.cache_creation_input == nil
    refute envelope.tokens.cached_input == 0
    refute envelope.tokens.cache_creation_input == 0
    assert :partial_update in envelope.coverage_reasons
    assert :missing_trusted_occurrence_time in envelope.coverage_reasons
    assert :unknown_account_generation in envelope.coverage_reasons

    assert Enum.map(coverage, & &1.field) == [
             :request_id,
             :cache_read_tokens,
             :cache_creation_tokens,
             :query_source,
             :effort,
             :cost_usd,
             :occurred_at
           ]

    assert Enum.all?(coverage, &(&1.class == :optional_field_absent))
    assert envelope.cache_write_duration == :not_applicable
  end

  test "fails closed with bounded coverage for unsupported contracts and identity gaps" do
    assert {:coverage, unsupported_source} =
             event(%{source_version: "claude-code-future"})
             |> UsageAdapter.normalize(@ingested_at)

    assert unsupported_source.class == :unsupported_source_revision
    assert unsupported_source.field == :source_version
    refute inspect(unsupported_source) =~ "future"

    missing_producer = update_in(event(), [:correlation], &Map.delete(&1, :producer_generation))
    assert {:coverage, %{class: :missing_required_identity, field: :producer_generation}} = UsageAdapter.normalize(missing_producer, @ingested_at)

    wrong_backend = put_in(event(), [:correlation, :backend], "claude")
    assert {:coverage, %{class: :ambiguous_measurement_semantics, field: :backend}} = UsageAdapter.normalize(wrong_backend, @ingested_at)

    missing_input = update_in(event(), [:attributes], &Map.delete(&1, "input_tokens"))
    assert {:coverage, %{class: :ambiguous_measurement_semantics, field: :input_tokens}} = UsageAdapter.normalize(missing_input, @ingested_at)

    unsafe_model = put_in(event(), [:attributes, "model"], "owner@example.invalid")
    assert {:coverage, unsafe_model_coverage} = UsageAdapter.normalize(unsafe_model, @ingested_at)
    assert unsafe_model_coverage == coverage(:ambiguous_measurement_semantics, :model)
    refute inspect(unsafe_model_coverage) =~ "owner@example.invalid"

    {:ok, empty_catalog} = RelationshipRegistry.new([])

    assert {:coverage, %{class: :unsupported_relationship_revision, field: :relationship_revision}} =
             UsageAdapter.normalize(event(), @ingested_at, empty_catalog)
  end

  test "preserves per-request model and effort changes without accepting disallowed data" do
    changed =
      event()
      |> put_in([:identity], {:request, "req_022222222222222222222222"})
      |> put_in([:attributes, "request_id"], "req_022222222222222222222222")
      |> put_in([:attributes, "model"], "claude-opus-4-6")
      |> put_in([:attributes, "effort"], "max")
      |> put_in([:attributes, "query_source"], "compact")
      |> put_in([:attributes, "prompt"], "TOP_SECRET")
      |> put_in([:correlation, :capability], "TOP_SECRET_CAPABILITY")

    assert {:ok, envelope, []} = UsageAdapter.normalize(changed, @ingested_at)
    assert envelope.resolved_model == "claude-opus-4-6"
    assert envelope.effort == "max"
    assert envelope.query_source == "compact"
    refute inspect(envelope) =~ "TOP_SECRET"
    refute inspect(envelope) =~ "CAPABILITY"
  end

  property "all supported token dimensions contribute exactly once" do
    check all(
            input <- integer(0..100_000),
            cache_create <- integer(0..100_000),
            cache_read <- integer(0..100_000),
            output <- integer(0..100_000),
            max_runs: 50
          ) do
      source =
        event()
        |> put_in([:attributes, "input_tokens"], input)
        |> put_in([:attributes, "cache_creation_tokens"], cache_create)
        |> put_in([:attributes, "cache_read_tokens"], cache_read)
        |> put_in([:attributes, "output_tokens"], output)

      assert {:ok, envelope, []} = UsageAdapter.normalize(source, @ingested_at)
      assert {:ok, %{canonical_total: total, coverage: :full}} = UsageEnvelope.reconcile(envelope, UsageAdapter.relationship_catalog())
      assert total == input + cache_create + cache_read + output
    end
  end

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        event: :api_request,
        source_version: "claude-code-2.1.210",
        transport: :otlp_http_json,
        identity: {:request, "req_011111111111111111111111"},
        occurred_at: ~U[2026-07-16 23:00:00Z],
        correlation: %{
          run_id: "run-1116",
          ticket: tracker_identity(),
          attempt_id: "attempt-1",
          worker_generation: 7,
          producer_generation: "producer-1",
          backend: "claude-repl",
          session_id: "11111111-1111-4111-8111-111111111111"
        },
        attributes: %{
          "event.sequence" => 17,
          "request_id" => "req_011111111111111111111111",
          "model" => "claude-sonnet-4-6",
          "cost_usd" => Decimal.new("0.0001234567890123456789"),
          "input_tokens" => 100,
          "output_tokens" => 10,
          "cache_read_tokens" => 30,
          "cache_creation_tokens" => 20,
          "query_source" => "repl_main_thread",
          "effort" => "high"
        }
      },
      overrides
    )
  end

  defp tracker_identity do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "I_kwDO1116",
      database_id: 1116,
      identifier: "1116",
      reason: nil
    }
  end

  defp coverage(class, field) do
    %{
      schema_version: 1,
      source: "claude_code.api_request",
      adapter_version: "claude-code-2.1.210",
      class: class,
      field: field
    }
  end
end
