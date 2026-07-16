defmodule Aiur.Usage.PricingFixture do
  alias Aiur.{TrackerIdentity, UsageEnvelope}
  alias Aiur.Usage.PriceTable
  alias Aiur.UsageEnvelope.RelationshipRegistry

  def codex_envelope!(overrides \\ %{}) do
    overrides
    |> envelope_attributes()
    |> UsageEnvelope.new()
    |> ok!()
  end

  def claude_envelope!(overrides \\ %{}) do
    base = %{
      idempotency_key: "claude:request-17",
      provider: :claude,
      source: "remote-control",
      source_version: "2026-07",
      source_event_id: "request-17",
      measurement_kind: :delta,
      counter_scope: :request,
      counter_epoch: "request-epoch-1",
      agent_family: :claude,
      backend: :remote_control,
      transport: :remote_control,
      auth_mode: :api_key,
      requested_model: "claude-opus-4-8",
      resolved_model: "claude-opus-4-8",
      account_generation: account_generation(:claude, :remote_control),
      tokens: %{
        input: 100,
        cached_input: 20,
        cache_creation_input: 30,
        output: 10,
        reasoning_output: 4,
        provider_reported_total: 160
      },
      relationship_revision: "claude-remote-control-2026-07"
    }

    base
    |> Map.merge(overrides)
    |> envelope_attributes()
    |> UsageEnvelope.new()
    |> ok!()
  end

  def codex_definition(overrides \\ %{}) do
    Map.merge(
      %{
        provider: :codex,
        source: "app-server",
        source_version: "2026-07",
        revision: "codex-app-server-2026-07",
        provider_total_authoritative: false,
        dimensions: %{
          input: :additive,
          cached_input: {:subset_of, :input},
          cache_creation_input: {:subset_of, :input},
          output: :additive,
          reasoning_output: {:subset_of, :output}
        }
      },
      overrides
    )
  end

  def claude_definition(overrides \\ %{}) do
    Map.merge(
      %{
        provider: :claude,
        source: "remote-control",
        source_version: "2026-07",
        revision: "claude-remote-control-2026-07",
        provider_total_authoritative: true,
        dimensions: %{
          input: :additive,
          cached_input: :additive,
          cache_creation_input: :additive,
          output: :additive,
          reasoning_output: {:subset_of, :output}
        }
      },
      overrides
    )
  end

  def registry!(definitions \\ [codex_definition(), claude_definition()]) do
    definitions |> RelationshipRegistry.new() |> ok!()
  end

  def default_price_table!, do: PriceTable.default() |> ok!()

  def price_table!(relationship_revision, overrides \\ %{}) do
    dimensions = [:input, :cached_input, :cache_creation_input, :output, :reasoning_output]

    entries =
      Enum.map(dimensions, fn dimension ->
        Map.merge(
          %{
            provider: :codex,
            resolved_model: "gpt-5.6-terra",
            token_dimension: dimension,
            relationship_revision: relationship_revision,
            currency: "USD",
            price: "1.00",
            token_unit: 1_000_000,
            effective_date: ~D[2026-07-15],
            price_revision: "test-price-1",
            source_url: "https://example.com/pricing",
            source_reviewed_at: ~D[2026-07-15],
            pricing_scope: "test"
          },
          overrides
        )
      end)

    PriceTable.new("test-table-1", entries) |> ok!()
  end

  def account_generation(provider \\ :codex, backend \\ :app_server) do
    %{
      provider: provider,
      backend: backend,
      generation: "generation-a",
      freshness: :current,
      health: :healthy,
      reason: nil
    }
  end

  def unknown_account_generation(provider \\ :codex, backend \\ :app_server) do
    %{
      provider: provider,
      backend: backend,
      generation: nil,
      freshness: :unknown,
      health: :unknown,
      reason: :never_observed
    }
  end

  def provider_cost(overrides \\ %{}) do
    Map.merge(
      %{
        amount: "0.0012",
        currency: "EUR",
        unit: :major,
        measurement_kind: :delta,
        counter_scope: :request,
        source: "structured-provider-estimate",
        source_version: "2026-07",
        coverage: :full
      },
      overrides
    )
  end

  defp envelope_attributes(overrides) do
    base = %{
      idempotency_key: "codex:event-17",
      provider: :codex,
      source: "app-server",
      source_version: "2026-07",
      source_event_id: "event-17",
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
      effort: "high",
      requested_model: "gpt-5.6-terra",
      resolved_model: "gpt-5.6-terra",
      account_generation: account_generation(),
      tokens: %{
        input: 100,
        cached_input: 40,
        cache_creation_input: 10,
        output: 30,
        reasoning_output: 10,
        provider_reported_total: 130
      },
      relationship_revision: "codex-app-server-2026-07",
      cost: provider_cost()
    }

    Map.merge(base, overrides)
  end

  defp attribution do
    %{
      run_id: "run-1117",
      tracker_identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "node-1117",
        database_id: 1117,
        identifier: "1117",
        reason: nil
      },
      attempt_id: "attempt-1",
      session_id: "session-1",
      thread_id: "thread-1",
      turn_id: "turn-1",
      request_id: "request-1"
    }
  end

  defp ok!({:ok, value}), do: value
end
