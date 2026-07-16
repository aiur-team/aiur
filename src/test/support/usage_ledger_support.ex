defmodule Aiur.TestSupport.UsageLedger do
  @moduledoc false

  alias Aiur.{TrackerIdentity, UsageEnvelope}

  def envelope(overrides \\ %{}) do
    {:ok, envelope} = UsageEnvelope.new(Map.merge(attributes(), overrides))
    envelope
  end

  def money(amount, kind \\ :absolute) do
    %{
      amount: amount,
      currency: "USD",
      unit: :major,
      measurement_kind: kind,
      counter_scope: :thread,
      source: "provider-cost",
      source_version: "2026-07"
    }
  end

  defp attributes do
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
        run_id: "run-1115",
        tracker_identity: %TrackerIdentity{
          status: :joinable,
          kind: :github,
          owner: "its-everdred",
          repository: "aiur",
          provider_id: "node-1115",
          database_id: 1115,
          identifier: "1115",
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
      tokens: token_values(10),
      relationship_revision: "codex-app-server-2026-07",
      cost: money("1.00")
    }
  end

  defp token_values(input) do
    %{
      input: input,
      cached_input: nil,
      cache_creation_input: nil,
      output: nil,
      reasoning_output: nil,
      provider_reported_total: nil
    }
  end
end
