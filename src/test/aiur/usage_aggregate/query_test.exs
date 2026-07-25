defmodule Aiur.UsageAggregate.QueryTest do
  use ExUnit.Case, async: true

  alias Aiur.TrackerIdentity
  alias Aiur.UsageAggregate.{Projection, Query}
  import Aiur.TestSupport.UsageAggregate, only: [envelope: 1, claude_envelope: 1, record: 3]

  defp identity(number) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "node-#{number}",
      database_id: number,
      identifier: Integer.to_string(number),
      reason: nil
    }
  end

  defp attribution(run_id, identity) do
    %{
      run_id: run_id,
      tracker_identity: identity,
      attempt_id: "attempt-1",
      session_id: "session-1",
      thread_id: "thread-1",
      turn_id: "turn-1",
      request_id: "request-1"
    }
  end

  defp state(projection) do
    %{
      projection: projection,
      health: :healthy,
      freshness: %{status: :fresh, projected_position: projection.source_position, ledger_position: projection.source_position, recovery: :clean},
      source_coverage: %{lower: 1, upper: projection.source_position, status: :full}
    }
  end

  defp scenario do
    ticket_one = envelope(%{attribution: attribution("run-A", identity(1))})
    ticket_one_more = envelope(%{attribution: attribution("run-A", identity(1))})
    ticket_two = claude_envelope(%{attribution: attribution("run-B", identity(2))})
    unknown_ticket = envelope(%{attribution: attribution("run-A", nil)})

    Projection.new()
    |> Projection.apply_record(record(1, ticket_one, %{tokens: %{input: 10}}))
    |> Projection.apply_record(record(2, ticket_one_more, %{tokens: %{input: 5}, cost: "1.00"}))
    |> Projection.apply_record(record(3, ticket_two, %{tokens: %{input: 7}}))
    |> Projection.apply_record(record(4, unknown_ticket, %{tokens: %{input: 3}}))
  end

  test "bounds a run-scoped query and reconciles every grouping to the total" do
    summary = Query.summary(state(scenario()), %{runs: ["run-A"]})

    assert summary.scope.status == :scoped
    assert summary.totals.tokens == %{input: 18}
    assert Decimal.equal?(summary.totals.money[{:provider_reported_estimate, "USD"}], Decimal.new("1.00"))
    assert summary.reconciliation.reconciled?

    # codex is the only provider under run-A; its group equals the total.
    assert summary.groups.by_provider[:codex].tokens == %{input: 18}
  end

  test "unions an explicit run set and typed ticket set without keying by bare issue number" do
    summary = Query.summary(state(scenario()), %{runs: ["run-A"], tickets: [identity(2), 1128, "1128"]})

    assert summary.totals.tokens == %{input: 25}
    assert summary.groups.by_provider[:claude].tokens == %{input: 7}
    # The bare issue number and string are rejected, never used as a scope key.
    assert summary.scope.rejected_tickets == 2
    assert summary.scope.tickets == [TrackerIdentity.github_key(identity(2))]
  end

  test "reports explicit unknown attribution inside the scope" do
    summary = Query.summary(state(scenario()), %{runs: ["run-A"]})

    assert summary.coverage.unknown_attribution.ticket == 1
    assert summary.coverage.selected_cells == 3
    assert summary.groups.by_ticket[:unknown].tokens == %{input: 3}
  end

  test "an empty scope is distinct from a populated one and returns zero totals" do
    summary = Query.summary(state(scenario()), %{})

    assert summary.scope.status == :empty
    assert summary.totals == %{tokens: %{}, money: %{}}
    assert summary.coverage.selected_cells == 0
  end

  test "identical dimensions under two relationship revisions stay separate groups" do
    revision_a = envelope(%{attribution: attribution("run-A", identity(1)), relationship_revision: "codex-app-server-2026-07"})
    revision_b = envelope(%{attribution: attribution("run-A", identity(1)), relationship_revision: "codex-app-server-2026-08"})

    projection =
      Projection.new()
      |> Projection.apply_record(record(1, revision_a, %{tokens: %{input: 10}}))
      |> Projection.apply_record(record(2, revision_b, %{tokens: %{input: 4}}))

    summary = Query.summary(state(projection), %{runs: ["run-A"]})

    assert map_size(summary.groups.by_relationship_revision) == 2
    assert summary.groups.by_relationship_revision["codex-app-server-2026-07"].tokens == %{input: 10}
    assert summary.groups.by_relationship_revision["codex-app-server-2026-08"].tokens == %{input: 4}
    assert summary.reconciliation.reconciled?
  end
end
