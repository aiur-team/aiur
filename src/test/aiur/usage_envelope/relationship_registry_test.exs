defmodule Aiur.UsageEnvelope.RelationshipRegistryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.{TrackerIdentity, UsageEnvelope}
  alias Aiur.UsageEnvelope.RelationshipRegistry

  test "reconciles additive and subset source contracts without double counting" do
    claude =
      definition(%{
        provider: :claude,
        source: "remote-control",
        source_version: "1",
        revision: "claude-1",
        dimensions: %{
          input: :additive,
          cached_input: :additive,
          cache_creation_input: :additive,
          output: :additive,
          reasoning_output: {:subset_of, :output}
        }
      })

    codex = definition()
    {:ok, catalog} = RelationshipRegistry.new([claude, codex])

    {:ok, claude_envelope} =
      UsageEnvelope.new(
        attributes(%{
          provider: :claude,
          agent_family: :claude,
          source: "remote-control",
          source_version: "1",
          relationship_revision: "claude-1",
          account_generation: account_generation(:claude),
          tokens: tokens(%{cache_creation_input: 3, reasoning_output: 2, provider_reported_total: 24})
        })
      )

    {:ok, codex_envelope} = UsageEnvelope.new(attributes())

    assert {:ok, %{canonical_total: 24, input_total: 17, output_total: 7, coverage: :full}} =
             RelationshipRegistry.reconcile(catalog, claude_envelope)

    assert {:ok, %{canonical_total: 17, input_total: 10, output_total: 7, coverage: :full}} =
             RelationshipRegistry.reconcile(catalog, codex_envelope)
  end

  test "fails closed for contradictory alternatives and unknown relationships" do
    alternatives =
      definition(%{
        revision: "alternatives-1",
        dimensions: %{
          input: {:mutually_exclusive, "prompt"},
          cached_input: {:mutually_exclusive, "prompt"},
          cache_creation_input: {:subset_of, :input},
          output: :additive,
          reasoning_output: {:subset_of, :output}
        }
      })

    unknown =
      definition(%{
        revision: "unknown-1",
        dimensions: Map.put(subset_dimensions(), :cached_input, :unknown)
      })

    {:ok, catalog} = RelationshipRegistry.new([alternatives, unknown])

    {:ok, contradiction} =
      UsageEnvelope.new(
        attributes(%{
          relationship_revision: "alternatives-1",
          tokens: tokens(%{input: 10, cached_input: 4, cache_creation_input: 1, provider_reported_total: nil})
        })
      )

    {:ok, unknown_envelope} =
      UsageEnvelope.new(attributes(%{relationship_revision: "unknown-1", tokens: tokens(%{provider_reported_total: nil})}))

    assert {:ok,
            %{
              canonical_total: nil,
              coverage: :unknown,
              coverage_reasons: reasons
            }} = RelationshipRegistry.reconcile(catalog, contradiction)

    assert :contradictory_relationship in reasons

    assert {:ok, %{canonical_total: nil, coverage_reasons: [:unknown_relationship]}} =
             RelationshipRegistry.reconcile(catalog, unknown_envelope)
  end

  test "keeps an authoritative provider total and exposes dimensional discrepancy" do
    {:ok, catalog} =
      RelationshipRegistry.new([
        definition(%{provider_total_authoritative: true})
      ])

    {:ok, envelope} =
      UsageEnvelope.new(attributes(%{tokens: tokens(%{provider_reported_total: 18})}))

    assert {:ok,
            %{
              canonical_total: 18,
              derived_total: 17,
              discrepancy: 1,
              status: :authoritative_discrepancy,
              coverage: :partial,
              coverage_reasons: [:provider_total_discrepancy]
            }} = RelationshipRegistry.reconcile(catalog, envelope)
  end

  test "resolves only the exact pinned historic revision" do
    old = definition(%{revision: "codex-1"})
    current = definition(%{revision: "codex-2", dimensions: Map.put(subset_dimensions(), :cached_input, :additive)})
    {:ok, catalog} = RelationshipRegistry.new([old, current])

    {:ok, retained} = UsageEnvelope.new(attributes(%{relationship_revision: "codex-1"}))
    {:ok, missing} = UsageEnvelope.new(attributes(%{relationship_revision: "codex-0"}))

    assert {:ok, %{canonical_total: 17, relationship_revision: "codex-1"}} =
             RelationshipRegistry.reconcile(catalog, retained)

    assert {:ok,
            %{
              canonical_total: nil,
              coverage: :unknown,
              coverage_reasons: [:missing_historic_relationship_revision]
            }} = RelationshipRegistry.reconcile(catalog, missing)
  end

  test "refuses to reinterpret an existing revision" do
    {:ok, catalog} = RelationshipRegistry.new([definition()])

    assert {:error, :relationship_revision_conflict} =
             RelationshipRegistry.register(
               catalog,
               definition(%{dimensions: Map.put(subset_dimensions(), :cached_input, :additive)})
             )
  end

  test "rejects cyclic subset definitions before they can omit dimensions" do
    cyclic =
      definition(%{
        dimensions: %{
          input: {:subset_of, :cached_input},
          cached_input: {:subset_of, :input},
          cache_creation_input: {:subset_of, :input},
          output: :additive,
          reasoning_output: {:subset_of, :output}
        }
      })

    assert {:error, :invalid_dimension_relationship} = RelationshipRegistry.new([cyclic])
  end

  property "subset dimensions never inflate canonical totals" do
    check all(
            input <- non_negative_integer(),
            cached <- integer(0..input),
            output <- non_negative_integer(),
            reasoning <- integer(0..output),
            max_runs: 50
          ) do
      {:ok, catalog} = RelationshipRegistry.new([definition()])

      {:ok, envelope} =
        UsageEnvelope.new(
          attributes(%{
            tokens:
              tokens(%{
                input: input,
                cached_input: cached,
                output: output,
                reasoning_output: reasoning,
                provider_reported_total: input + output
              })
          })
        )

      assert {:ok, %{canonical_total: total, coverage: :full}} =
               RelationshipRegistry.reconcile(catalog, envelope)

      assert total == input + output
      assert envelope.tokens.cached_input == cached
      assert envelope.tokens.reasoning_output == reasoning
    end
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
        attribution: attribution(),
        agent_family: :codex,
        backend: :app_server,
        transport: :app_server,
        auth_mode: :chatgpt,
        account_generation: account_generation(:codex),
        tokens: tokens(),
        relationship_revision: "codex-app-server-2026-07"
      },
      overrides
    )
  end

  defp tokens(overrides \\ %{}) do
    Map.merge(
      %{
        input: 10,
        cached_input: 4,
        cache_creation_input: nil,
        output: 7,
        reasoning_output: 2,
        provider_reported_total: 17
      },
      overrides
    )
  end

  defp account_generation(provider) do
    %{
      provider: provider,
      backend: :app_server,
      generation: "generation-a",
      freshness: :current,
      health: :healthy,
      reason: nil
    }
  end

  defp attribution do
    %{
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
    }
  end
end
