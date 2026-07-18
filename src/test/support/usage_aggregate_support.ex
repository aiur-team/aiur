defmodule Aiur.TestSupport.UsageAggregate do
  @moduledoc false

  alias Aiur.TestSupport.UsageLedger, as: LedgerSupport
  alias Aiur.UsageEnvelope.ExactMoney

  @token_dimensions [:input, :cached_input, :cache_creation_input, :output, :reasoning_output, :provider_reported_total]

  @doc "A codex delta-measurement envelope with unique idempotency by default."
  def envelope(overrides \\ %{}) do
    LedgerSupport.envelope(Map.merge(delta_defaults(), overrides))
  end

  @doc "A claude delta-measurement envelope for cross-provider fixtures."
  def claude_envelope(overrides \\ %{}) do
    claude =
      %{
        provider: :claude,
        source: "otlp",
        source_version: "claude-2026-07",
        agent_family: :claude,
        backend: :remote_control,
        transport: :otlp,
        auth_mode: :api_key,
        requested_model: "claude-sonnet-4-6",
        resolved_model: "claude-sonnet-4-6",
        relationship_revision: "claude-otlp-2026-07",
        account_generation: %{
          provider: :claude,
          backend: :remote_control,
          generation: "generation-c",
          freshness: :current,
          health: :healthy,
          reason: nil
        }
      }

    envelope(Map.merge(claude, overrides))
  end

  @doc "Builds a DASH-009 replay record for pure projection/query tests."
  def record(position, envelope, delta_overrides \\ %{}) do
    delta = delta(delta_overrides)

    %{
      position: position,
      generation: position,
      envelope: envelope,
      delta: delta,
      source_version: envelope.source_version,
      relationship_revision: envelope.relationship_revision,
      coverage_reasons: envelope.coverage_reasons
    }
  end

  @doc "A ledger delta payload; `:tokens` accepts a sparse dimension map."
  def delta(overrides \\ %{}) do
    tokens = overrides |> Map.get(:tokens, %{input: 10}) |> tokens()
    cost = overrides |> Map.get(:cost, nil) |> cost()

    %{
      tokens: tokens,
      cost: cost,
      source_version: Map.get(overrides, :source_version, "2026-07"),
      relationship_revision: Map.get(overrides, :relationship_revision, "codex-app-server-2026-07"),
      coverage_reasons: Map.get(overrides, :coverage_reasons, [])
    }
  end

  @doc "A delta-basis ExactMoney struct for cost fixtures."
  def money(amount) do
    {:ok, money} = ExactMoney.decode(LedgerSupport.money(amount, :delta))
    money
  end

  def tokens(sparse) when is_map(sparse) do
    Map.new(@token_dimensions, fn dimension -> {dimension, Map.get(sparse, dimension)} end)
  end

  defp cost(nil), do: nil
  defp cost(%ExactMoney{} = money), do: money
  defp cost(amount) when is_binary(amount), do: money(amount)

  defp delta_defaults do
    unique = System.unique_integer([:positive])

    %{
      idempotency_key: "codex:evt-#{unique}",
      source_event_id: "evt-#{unique}",
      source_sequence: unique,
      measurement_kind: :delta,
      cost: nil
    }
  end
end
