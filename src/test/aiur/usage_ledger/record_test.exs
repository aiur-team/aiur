defmodule Aiur.UsageLedger.RecordTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Aiur.{TrackerIdentity, UsageEnvelope}
  alias Aiur.UsageLedger.{CounterPolicy, Record}

  test "round-trips a versioned canonical record without changing source-version or relationship revision" do
    envelope = envelope()
    assert {:ok, %{delta: delta}} = CounterPolicy.apply(CounterPolicy.new(), envelope)
    assert {:ok, record} = Record.new(7, envelope, delta)

    assert {:ok, decoded} = record |> Record.encode() |> Jason.encode!() |> Jason.decode!() |> Record.decode()
    assert decoded.position == 7
    assert decoded.envelope.source_version == envelope.source_version
    assert decoded.envelope.relationship_revision == envelope.relationship_revision
    assert decoded.delta.relationship_revision == envelope.relationship_revision
    assert Decimal.equal?(decoded.delta.cost.amount, Decimal.new("1.00"))
  end

  test "rejects content-bearing values at the ledger admission boundary" do
    path_envelope = envelope(source: "/private/provider-response")
    assert {:error, :content_rejected} = Record.admit(path_envelope)

    credential_envelope = envelope(idempotency_key: "sk-secret-value")
    assert {:error, :content_rejected} = Record.admit(credential_envelope)

    for credential <- ["ghp_0123456789abcdef", "xoxb-0123456789", "AKIA0123456789ABCDEF"] do
      assert {:error, :content_rejected} = Record.admit(envelope(idempotency_key: credential))
    end
  end

  test "rejects forged record schema and delta evidence" do
    envelope = envelope()
    assert {:ok, %{delta: delta}} = CounterPolicy.apply(CounterPolicy.new(), envelope)
    {:ok, record} = Record.new(1, envelope, delta)
    encoded = Record.encode(record)

    assert {:error, :unsupported_ledger_record_version} = Record.decode(Map.put(encoded, "schema_version", 99))

    assert {:error, :invalid_ledger_delta} =
             Record.decode(put_in(encoded, ["delta", "relationship_revision"], "current-registry-revision"))
  end

  test "rejects token, source-sequence, and tracker database integers outside the ledger bound" do
    huge_integer = 1 <<< 100_000

    for oversized <- [
          envelope(tokens: token_values(huge_integer)),
          envelope(source_sequence: huge_integer),
          envelope(attribution: %{envelope().attribution | tracker_identity: %{envelope().attribution.tracker_identity | database_id: huge_integer}})
        ] do
      assert {:error, :numeric_value_out_of_bounds} = Record.admit(oversized)
      assert {:error, :numeric_value_out_of_bounds, _state} = CounterPolicy.apply(CounterPolicy.new(), oversized)
    end
  end

  defp envelope(overrides \\ %{}) do
    {:ok, envelope} =
      UsageEnvelope.new(
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
            cost: %{
              amount: "1.00",
              currency: "USD",
              unit: :major,
              measurement_kind: :absolute,
              counter_scope: :thread,
              source: "provider-cost",
              source_version: "2026-07"
            }
          },
          Map.new(overrides)
        )
      )

    envelope
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
