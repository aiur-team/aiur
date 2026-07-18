defmodule Aiur.UsageEnvelope.CodecTest do
  use ExUnit.Case, async: true

  alias Aiur.{TrackerIdentity, UsageEnvelope}
  alias Aiur.UsageEnvelope.{Codec, ExactMoney}

  test "round-trips canonical money while retaining its exact source representation" do
    {:ok, envelope} = UsageEnvelope.new(attributes())
    record = Codec.encode(envelope)

    assert record["cost"]["amount"] == "1.00"
    assert record["cost"]["unit"] == "major"
    assert record["cost"]["source_representation"] == "minor"
    assert record["query_source"] == "repl_main_thread"
    assert {:ok, decoded} = Codec.decode(record)
    assert decoded == envelope

    assert {:ok, json_decoded} = record |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
    assert json_decoded == envelope
  end

  test "rejects forged derived dates and unexpected content-bearing fields" do
    {:ok, envelope} = UsageEnvelope.new(attributes())
    record = Codec.encode(envelope)

    assert {:error, :invalid_pricing_effective_date} =
             Codec.decode(Map.put(record, "pricing_effective_date", "2026-07-16"))

    assert {:error, :invalid_envelope_field} =
             Codec.decode(Map.put(record, "raw_payload", %{"prompt" => "secret"}))

    assert {:error, :invalid_money_field} =
             Codec.decode(put_in(record, ["cost", "credential"], "secret"))
  end

  test "never coerces absent or imprecise cost to zero" do
    assert {:ok, nil} = ExactMoney.decode(nil)
    assert {:error, :float_not_allowed} = ExactMoney.decode(money(%{amount: 0.1, unit: :major}))
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
      query_source: "repl_main_thread",
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
      cost: money()
    }
  end

  defp money(overrides \\ %{}) do
    Map.merge(
      %{
        amount: 100,
        currency: "USD",
        unit: :minor,
        minor_unit_scale: 2,
        measurement_kind: :delta,
        counter_scope: :request,
        source: "provider-cost",
        source_version: "2026-07"
      },
      overrides
    )
  end
end
