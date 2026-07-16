defmodule Aiur.UsageLedger.CounterPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.{TrackerIdentity, UsageEnvelope}
  alias Aiur.UsageLedger.CounterPolicy

  test "derives monotonic absolute token and exact-cost deltas without changing source evidence" do
    first = envelope(tokens: %{input: 10, output: 7}, cost: money("1.00", :absolute))

    second =
      envelope(
        idempotency_key: "codex:evt-18",
        source_event_id: "evt-18",
        source_sequence: 18,
        tokens: %{input: 17, output: 7},
        cost: money("1.30", :absolute)
      )

    assert {:ok, %{delta: first_delta, state: state}} = CounterPolicy.apply(CounterPolicy.new(), first)
    assert first_delta.tokens.input == 10
    assert first_delta.tokens.output == 7
    assert Decimal.equal?(first_delta.cost.amount, Decimal.new("1.00"))

    assert {:ok, %{delta: second_delta, state: _state}} = CounterPolicy.apply(state, second)
    assert second_delta.tokens.input == 7
    assert second_delta.tokens.output == 0
    assert Decimal.equal?(second_delta.cost.amount, Decimal.new("0.30"))
    assert second_delta.source_version == "2026-07"
    assert second_delta.relationship_revision == "codex-app-server-2026-07"
  end

  test "deduplicates source deltas and accepts older absolute observations without rewinding" do
    source_delta = envelope(measurement_kind: :delta, tokens: %{input: 5}, cost: money("0.20", :delta))
    assert {:ok, %{delta: delta, state: state}} = CounterPolicy.apply(CounterPolicy.new(), source_delta)
    assert delta.tokens.input == 5
    assert {:duplicate, ^state} = CounterPolicy.apply(state, source_delta)

    first = envelope(tokens: %{input: 10})

    older =
      envelope(
        idempotency_key: "codex:evt-16",
        source_event_id: "evt-16",
        source_sequence: 16,
        tokens: %{input: 18},
        cost: money("1.50", :absolute)
      )

    assert {:ok, %{state: absolute_state}} = CounterPolicy.apply(CounterPolicy.new(), first)
    assert {:ok, %{delta: stale_delta}} = CounterPolicy.apply(absolute_state, older)
    assert stale_delta.tokens.input == 0
    assert Decimal.equal?(stale_delta.cost.amount, Decimal.new(0))
  end

  test "rejects a newer unexplained decrease but establishes new epochs and models independently" do
    first = envelope(tokens: %{input: 10})
    lower = envelope(idempotency_key: "codex:evt-18", source_event_id: "evt-18", source_sequence: 18, tokens: %{input: 8})

    assert {:ok, %{state: state}} = CounterPolicy.apply(CounterPolicy.new(), first)
    assert {:error, :counter_decreased, ^state} = CounterPolicy.apply(state, lower)

    reset =
      envelope(
        idempotency_key: "codex:evt-19",
        source_event_id: "evt-19",
        source_sequence: 19,
        counter_epoch: "thread-epoch-2",
        tokens: %{input: 3}
      )

    assert {:ok, %{delta: reset_delta, state: reset_state}} = CounterPolicy.apply(state, reset)
    assert reset_delta.tokens.input == 3

    fallback =
      envelope(
        idempotency_key: "codex:evt-20",
        source_event_id: "evt-20",
        source_sequence: 20,
        resolved_model: "gpt-5.7-terra",
        tokens: %{input: 4}
      )

    assert {:ok, %{delta: fallback_delta}} = CounterPolicy.apply(reset_state, fallback)
    assert fallback_delta.tokens.input == 4
  end

  test "rejects overlapping source-delta and absolute streams without mutating state" do
    absolute = envelope(tokens: %{input: 10})

    delta =
      envelope(
        idempotency_key: "codex:evt-18",
        source_event_id: "evt-18",
        source_sequence: 18,
        measurement_kind: :delta,
        tokens: %{input: 2},
        cost: money("0.10", :delta)
      )

    assert {:ok, %{state: state}} = CounterPolicy.apply(CounterPolicy.new(), absolute)
    assert {:error, :mixed_measurement_stream, ^state} = CounterPolicy.apply(state, delta)
  end

  test "partitions account rotation, retry scope, resumed sessions, and historical source revisions" do
    first = envelope(tokens: %{input: 10})
    assert {:ok, %{state: state}} = CounterPolicy.apply(CounterPolicy.new(), first)

    rotated =
      envelope(
        idempotency_key: "codex:evt-18",
        source_event_id: "evt-18",
        source_sequence: 18,
        account_generation: account_generation("generation-b"),
        tokens: %{input: 2}
      )

    assert {:ok, %{delta: rotated_delta, state: state}} = CounterPolicy.apply(state, rotated)
    assert rotated_delta.tokens.input == 2

    retried_attribution = Map.put(first.attribution, :attempt_id, "attempt-2")

    retried =
      envelope(
        idempotency_key: "codex:evt-19",
        source_event_id: "evt-19",
        source_sequence: 19,
        attribution: retried_attribution,
        tokens: %{input: 10}
      )

    assert {:ok, %{delta: retry_delta, state: state}} = CounterPolicy.apply(state, retried)
    assert retry_delta.tokens.input == 0

    resumed =
      envelope(
        idempotency_key: "codex:evt-20",
        source_event_id: "evt-20",
        source_sequence: 20,
        attribution: Map.put(first.attribution, :session_id, "session-2"),
        tokens: %{input: 4}
      )

    assert {:ok, %{delta: resumed_delta, state: state}} = CounterPolicy.apply(state, resumed)
    assert resumed_delta.tokens.input == 4

    historical =
      envelope(
        idempotency_key: "codex:evt-21",
        source_event_id: "evt-21",
        source_sequence: 21,
        source_version: "2026-08",
        relationship_revision: "codex-app-server-2026-08",
        tokens: %{input: 5}
      )

    assert {:ok, %{delta: historical_delta}} = CounterPolicy.apply(state, historical)
    assert historical_delta.tokens.input == 5
    assert historical_delta.source_version == "2026-08"
    assert historical_delta.relationship_revision == "codex-app-server-2026-08"
  end

  test "uses the declared counter scope and namespaces identical source ids" do
    first = envelope(tokens: %{input: 10})
    assert {:ok, %{state: state}} = CounterPolicy.apply(CounterPolicy.new(), first)

    next_request =
      envelope(
        idempotency_key: "codex:evt-18",
        source_event_id: "evt-18",
        source_sequence: 18,
        attribution: Map.put(first.attribution, :request_id, "request-2"),
        tokens: %{input: 10}
      )

    assert {:ok, %{delta: request_delta, state: state}} = CounterPolicy.apply(state, next_request)
    assert request_delta.tokens.input == 0

    other_source =
      envelope(
        idempotency_key: first.idempotency_key,
        source_event_id: first.source_event_id,
        source_sequence: 19,
        source_version: "2026-08",
        relationship_revision: "codex-app-server-2026-08",
        tokens: %{input: 4}
      )

    assert {:ok, %{delta: source_delta}} = CounterPolicy.apply(state, other_source)
    assert source_delta.tokens.input == 4
  end

  defp envelope(overrides) do
    attributes = %{
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
      account_generation: account_generation("generation-a"),
      tokens: token_values(10),
      relationship_revision: "codex-app-server-2026-07",
      cost: money("1.00", :absolute)
    }

    {:ok, envelope} = UsageEnvelope.new(Map.merge(attributes, Map.new(overrides)))
    envelope
  end

  defp money(amount, kind) do
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

  defp account_generation(generation) do
    %{
      provider: :codex,
      backend: :app_server,
      generation: generation,
      freshness: :current,
      health: :healthy,
      reason: nil
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
