defmodule Aiur.UsageEnvelope.CompatibilityTest do
  use ExUnit.Case, async: true

  alias Aiur.{TokenUsage, TrackerIdentity, UsageEnvelope}
  alias Aiur.UsageEnvelope.RelationshipRegistry

  test "projects a safely reconciled transient view without changing legacy normalization" do
    {:ok, catalog} = RelationshipRegistry.new([definition()])
    {:ok, envelope} = UsageEnvelope.new(attributes())

    assert {:ok,
            %{
              input_tokens: 10,
              output_tokens: 7,
              total_tokens: 17,
              coverage: :full,
              provider_account_generation: "generation-a",
              source_identity: %{counter_epoch: "thread-epoch-1"}
            }} = UsageEnvelope.compatibility_projection(envelope, catalog)

    assert TokenUsage.canonicalize(%{"inputTokens" => 7}) == %{
             input_tokens: 7,
             output_tokens: 0,
             total_tokens: 0
           }
  end

  test "carries an authoritative total while keeping partial dimensions explicit" do
    definition =
      definition(%{
        provider_total_authoritative: true,
        dimensions: Map.put(subset_dimensions(), :cached_input, :unknown)
      })

    {:ok, catalog} = RelationshipRegistry.new([definition])
    {:ok, envelope} = UsageEnvelope.new(attributes(%{update_kind: :partial}))

    assert {:ok,
            %{
              input_tokens: nil,
              output_tokens: 7,
              total_tokens: 17,
              coverage: :partial,
              coverage_reasons: reasons
            }} = UsageEnvelope.compatibility_projection(envelope, catalog)

    assert :unknown_relationship in reasons
    assert :partial_update in reasons
  end

  test "does not derive cross-message deltas or substitute identity namespaces" do
    {:ok, catalog} = RelationshipRegistry.new([definition()])

    {:ok, first} = UsageEnvelope.new(attributes())

    {:ok, later} =
      UsageEnvelope.new(
        attributes(%{
          idempotency_key: "codex:evt-18",
          source_event_id: "evt-18",
          source_sequence: 18,
          counter_epoch: "thread-epoch-2",
          tokens: Map.put(tokens(), :provider_reported_total, 9),
          account_generation: Map.put(account_generation(), :generation, "generation-b")
        })
      )

    {:ok, first_projection} = UsageEnvelope.compatibility_projection(first, catalog)
    {:ok, later_projection} = UsageEnvelope.compatibility_projection(later, catalog)

    assert first_projection.total_tokens == 17
    assert later_projection.total_tokens == 17
    assert first_projection.provider_account_generation == "generation-a"
    assert later_projection.provider_account_generation == "generation-b"
    refute first_projection.source_identity.counter_epoch == later_projection.source_identity.counter_epoch
  end

  defp definition(overrides \\ %{}) do
    Map.merge(
      %{
        provider: :codex,
        source: "app-server",
        source_version: "2026-07",
        revision: "codex-app-server-2026-07",
        provider_total_authoritative: false,
        dimensions: subset_dimensions()
      },
      overrides
    )
  end

  defp subset_dimensions do
    %{
      input: :additive,
      cached_input: {:subset_of, :input},
      cache_creation_input: {:subset_of, :input},
      output: :additive,
      reasoning_output: {:subset_of, :output}
    }
  end

  defp attributes(overrides \\ %{}) do
    Map.merge(
      %{
        idempotency_key: "codex:evt-17",
        provider: :codex,
        source: "app-server",
        source_version: "2026-07",
        source_event_id: "evt-17",
        source_sequence: 17,
        occurred_at: ~U[2026-07-15 00:00:00Z],
        ingested_at: ~U[2026-07-15 00:00:02Z],
        measurement_kind: :absolute,
        counter_scope: :thread,
        counter_epoch: "thread-epoch-1",
        update_kind: :full,
        attribution: %{
          run_id: "run-1114",
          tracker_identity: %TrackerIdentity{
            status: :joinable,
            kind: :github,
            owner: "its-everdred",
            repository: "aiur",
            provider_id: "node-1114",
            database_id: 1114,
            identifier: "1114",
            reason: nil
          },
          attempt_id: "attempt-1",
          session_id: "session-1",
          thread_id: "thread-1",
          turn_id: "turn-1",
          request_id: "request-1"
        },
        agent_family: :codex,
        backend: :app_server,
        transport: :app_server,
        auth_mode: :chatgpt,
        account_generation: account_generation(),
        tokens: tokens(),
        relationship_revision: "codex-app-server-2026-07"
      },
      overrides
    )
  end

  defp tokens do
    %{
      input: 10,
      cached_input: 4,
      cache_creation_input: nil,
      output: 7,
      reasoning_output: 2,
      provider_reported_total: 17
    }
  end

  defp account_generation do
    %{
      provider: :codex,
      backend: :app_server,
      generation: "generation-a",
      freshness: :current,
      health: :healthy,
      reason: nil
    }
  end
end
