defmodule Aiur.UsageEnvelopeTest do
  use ExUnit.Case, async: true

  alias Aiur.{TrackerIdentity, UsageEnvelope}
  alias Aiur.UsageEnvelope.{Codec, ExactMoney}

  describe "new/1" do
    test "preserves a complete trusted raw measurement and its UTC pricing bucket" do
      {:ok, envelope} = UsageEnvelope.new(attributes())

      assert envelope.schema_version == 1
      assert envelope.idempotency_key == "codex:evt-17"
      assert envelope.pricing_effective_date == ~D[2026-07-15]
      assert envelope.account_generation.generation == "generation-a"
      assert envelope.tokens.cached_input == 4
      assert Decimal.equal?(envelope.cost.amount, Decimal.new("1.23"))
      assert UsageEnvelope.raw_identity(envelope).cost_currency == "USD"
      assert UsageEnvelope.raw_identity(envelope).resolved_model == "gpt-5.6-terra"
      assert UsageEnvelope.raw_identity(envelope).provider_account_generation == "generation-a"
      refute Map.has_key?(UsageEnvelope.raw_identity(envelope), :query_source)
      assert envelope.query_source == "repl_main_thread"

      assert {:ok, decoded} = envelope |> Codec.encode() |> Codec.decode()
      assert decoded == envelope
    end

    test "leaves the pricing bucket explicitly unknown without trusted occurrence time" do
      {:ok, envelope} = UsageEnvelope.new(attributes(%{occurred_at: nil}))

      assert envelope.pricing_effective_date == nil
      assert :missing_trusted_occurrence_time in envelope.coverage_reasons
    end

    test "requires deterministic source identity for counter-bearing measurements" do
      assert {:error, :missing_source_sequence} =
               UsageEnvelope.new(attributes() |> Map.delete(:source_sequence))

      assert {:error, :missing_counter_epoch} =
               UsageEnvelope.new(attributes() |> Map.delete(:counter_epoch))
    end

    test "rejects an envelope with neither token nor cost evidence" do
      empty_tokens = Map.new(UsageEnvelope.token_dimensions() ++ [:provider_reported_total], &{&1, nil})

      assert {:error, :missing_usage_measurement} =
               UsageEnvelope.new(attributes(%{tokens: empty_tokens, cost: nil}))
    end

    test "keeps account generations separate from counter epochs" do
      assert {:error, :account_generation_used_as_counter_epoch} =
               UsageEnvelope.new(attributes(%{counter_epoch: "generation-a"}))
    end

    test "accepts explicit unknown account context but rejects an unhealthy known generation" do
      assert {:ok, envelope} =
               UsageEnvelope.new(
                 attributes(%{
                   account_generation: %{
                     provider: :codex,
                     backend: :app_server,
                     generation: nil,
                     freshness: :unknown,
                     health: :unknown,
                     reason: :never_observed
                   }
                 })
               )

      assert envelope.account_generation.generation == nil

      assert {:error, :invalid_account_generation_context} =
               UsageEnvelope.new(
                 attributes(%{
                   account_generation: %{
                     provider: :codex,
                     backend: :app_server,
                     generation: "generation-a",
                     freshness: :unknown,
                     health: :unknown,
                     reason: :continuity_lost
                   }
                 })
               )
    end

    test "preserves source ordering and attribution facts without deriving deduplication" do
      {:ok, original} = UsageEnvelope.new(attributes())

      {:ok, reordered} =
        UsageEnvelope.new(
          attributes(%{
            idempotency_key: "codex:evt-16",
            source_event_id: "evt-16",
            source_sequence: 16,
            counter_epoch: "thread-epoch-0",
            attribution:
              attributes().attribution
              |> Map.put(:attempt_id, "attempt-2")
              |> Map.put(:session_id, "session-2")
          })
        )

      assert original.source_sequence == 17
      assert reordered.source_sequence == 16
      assert original.attribution.attempt_id == "attempt-1"
      assert reordered.attribution.attempt_id == "attempt-2"
      refute original.idempotency_key == reordered.idempotency_key
      refute original.counter_epoch == reordered.counter_epoch
    end

    test "rejects forged attribution and account-context fields" do
      assert {:error, :invalid_attribution} =
               UsageEnvelope.new(attributes(%{attribution: Map.put(attributes().attribution, :prompt, "secret")}))

      assert {:error, :invalid_account_generation_context} =
               UsageEnvelope.new(
                 attributes(%{
                   account_generation: Map.put(attributes().account_generation, :credential, "secret")
                 })
               )
    end

    test "rejects non-UTF-8 opaque values before JSON serialization" do
      invalid_utf8 = <<255>>

      assert {:error, :invalid_source} =
               UsageEnvelope.new(attributes(%{source: invalid_utf8}))

      assert {:error, :invalid_attribution} =
               UsageEnvelope.new(
                 attributes(%{
                   attribution: Map.put(attributes().attribution, :run_id, invalid_utf8)
                 })
               )

      assert {:error, :invalid_account_generation_context} =
               UsageEnvelope.new(
                 attributes(%{
                   account_generation: Map.put(attributes().account_generation, :generation, invalid_utf8)
                 })
               )

      assert {:error, :invalid_relationship_revision} =
               UsageEnvelope.new(attributes(%{relationship_revision: invalid_utf8}))
    end
  end

  describe "ExactMoney.decode/1" do
    test "normalizes tagged exact major and minor money representations" do
      assert {:ok, major} =
               ExactMoney.decode(%{
                 amount: "1.00",
                 currency: "USD",
                 unit: :major,
                 measurement_kind: :delta,
                 counter_scope: :request,
                 source: "provider-cost",
                 source_version: "2026-07"
               })

      assert {:ok, minor} =
               ExactMoney.decode(%{
                 amount: 100,
                 currency: "USD",
                 unit: :minor,
                 minor_unit_scale: 2,
                 measurement_kind: :delta,
                 counter_scope: :request,
                 source: "provider-cost",
                 source_version: "2026-07"
               })

      assert Decimal.equal?(major.amount, minor.amount)
      assert minor.minor_unit_scale == 2
      assert ExactMoney.to_map(minor)["amount"] == "1.00"
    end

    test "rejects decoded floats and incomplete or ambiguous money" do
      assert {:error, :float_not_allowed} = ExactMoney.decode(money_attrs(%{amount: 1.0, unit: :major}))
      assert {:error, :missing_minor_unit_scale} = ExactMoney.decode(money_attrs(%{amount: 100, unit: :minor}))
      assert {:error, :invalid_currency} = ExactMoney.decode(money_attrs(%{currency: "usd"}))
      assert {:error, :invalid_money} = ExactMoney.decode(money_attrs(%{amount: "NaN", unit: :major}))

      assert {:error, :unexpected_minor_unit_scale} =
               ExactMoney.decode(money_attrs(%{amount: "1.00", unit: :major, minor_unit_scale: 2}))

      assert {:error, :money_too_large} =
               ExactMoney.decode(money_attrs(%{amount: String.duplicate("9", 129), unit: :major}))
    end

    test "requires canonical major amounts to be exact at their declared minor scale" do
      canonical_minor = %{
        amount: "1.23",
        unit: :major,
        source_representation: :minor,
        minor_unit_scale: 2
      }

      assert {:ok, money} = ExactMoney.decode(money_attrs(canonical_minor))
      assert money.source_representation == :minor
      assert money.minor_unit_scale == 2

      assert {:error, :inexact_minor_unit_amount} =
               ExactMoney.decode(money_attrs(%{canonical_minor | amount: "1.234"}))
    end

    test "rejects non-UTF-8 money scalars before JSON serialization" do
      invalid_utf8 = <<255>>

      assert {:error, :invalid_money} =
               ExactMoney.decode(money_attrs(%{source: invalid_utf8}))

      assert {:error, :invalid_currency} =
               ExactMoney.decode(money_attrs(%{currency: invalid_utf8}))

      assert {:error, :invalid_money} =
               ExactMoney.decode(money_attrs(%{amount: invalid_utf8}))
    end
  end

  describe "occurrence-price partition dimensions" do
    test "codex retains context_tier and round-trips through the codec" do
      {:ok, envelope} = UsageEnvelope.new(attributes(%{context_tier: :long_context}))

      assert envelope.context_tier == :long_context
      assert envelope.cache_write_duration == nil

      assert {:ok, decoded} = envelope |> Codec.encode() |> Codec.decode()
      assert decoded == envelope
      assert Codec.encode(envelope)["context_tier"] == "long_context"
    end

    test "defaults to absent partitions when the adapter does not supply them" do
      {:ok, envelope} = UsageEnvelope.new(attributes())

      assert envelope.context_tier == nil
      assert envelope.cache_write_duration == nil
    end

    test "rejects a codex partition that is not a valid context tier" do
      assert {:error, :invalid_context_tier} =
               UsageEnvelope.new(attributes(%{context_tier: :not_applicable}))

      assert {:error, :invalid_context_tier} =
               UsageEnvelope.new(attributes(%{context_tier: :unbounded}))

      assert {:error, :invalid_cache_write_duration} =
               UsageEnvelope.new(attributes(%{context_tier: :short_context, cache_write_duration: :five_minutes}))
    end

    test "claude retains cache_write_duration and round-trips through the codec" do
      {:ok, envelope} =
        UsageEnvelope.new(
          claude_attributes(%{
            cache_write_duration: :one_hour,
            tokens: %{attributes().tokens | cache_creation_input: 2}
          })
        )

      assert envelope.context_tier == nil
      assert envelope.cache_write_duration == :one_hour

      assert {:ok, decoded} = envelope |> Codec.encode() |> Codec.decode()
      assert decoded == envelope
    end

    test "claude retains a five_minutes cache_write_duration and round-trips through the codec" do
      {:ok, envelope} =
        UsageEnvelope.new(
          claude_attributes(%{
            cache_write_duration: :five_minutes,
            tokens: %{attributes().tokens | cache_creation_input: 2}
          })
        )

      assert envelope.cache_write_duration == :five_minutes
      assert envelope.context_tier == nil

      assert {:ok, decoded} = envelope |> Codec.encode() |> Codec.decode()
      assert decoded == envelope
    end

    test "claude accepts not_applicable for an observation without cache creation" do
      assert {:ok, envelope} =
               UsageEnvelope.new(claude_attributes(%{cache_write_duration: :not_applicable}))

      assert envelope.cache_write_duration == :not_applicable
    end

    test "rejects a claude partition that mixes providers or uses an unknown duration" do
      assert {:error, :invalid_context_tier} =
               UsageEnvelope.new(claude_attributes(%{context_tier: :short_context}))

      assert {:error, :invalid_cache_write_duration} =
               UsageEnvelope.new(claude_attributes(%{cache_write_duration: :session}))
    end
  end

  defp claude_attributes(overrides) do
    attributes(
      Map.merge(
        %{
          idempotency_key: "claude:evt-17",
          provider: :claude,
          source: "otlp",
          source_version: "claude-2026-07",
          agent_family: :claude,
          backend: :remote_control,
          transport: :otlp,
          auth_mode: :api_key,
          requested_model: "claude-opus-4-8",
          resolved_model: "claude-opus-4-8",
          relationship_revision: "claude-remote-control-2026-07",
          account_generation: %{
            provider: :claude,
            backend: :remote_control,
            generation: "generation-c",
            freshness: :current,
            health: :healthy,
            reason: nil
          }
        },
        overrides
      )
    )
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
          tracker_identity: tracker_identity(),
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
        effort: "high",
        query_source: "repl_main_thread",
        requested_model: "gpt-5.6-terra",
        resolved_model: "gpt-5.6-terra",
        account_generation: %{
          provider: :codex,
          backend: :app_server,
          generation: "generation-a",
          freshness: :current,
          health: :healthy,
          reason: nil
        },
        tokens: %{
          input: 10,
          cached_input: 4,
          cache_creation_input: nil,
          output: 7,
          reasoning_output: nil,
          provider_reported_total: 17
        },
        relationship_revision: "codex-app-server-2026-07",
        cost: money_attrs()
      },
      overrides
    )
  end

  defp money_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        amount: "1.23",
        currency: "USD",
        unit: :major,
        measurement_kind: :delta,
        counter_scope: :request,
        source: "provider-cost",
        source_version: "2026-07"
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
      provider_id: "node-1114",
      database_id: 1114,
      identifier: "1114",
      reason: nil
    }
  end
end
