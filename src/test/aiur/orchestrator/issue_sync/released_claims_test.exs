defmodule Aiur.Orchestrator.IssueSync.ReleasedClaimsTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  test "purges released claims once the ticket is confirmed terminal or gone (#1475)" do
    active = issue("released-active", "in-progress")
    closed = issue("released-closed", "done")
    vanished = issue("released-vanished", "todo")

    release = %{cause: :rate_limit, details: %{}, released_at_ms: 1}

    state = %State{
      last_polled_issues: %{active.id => active, closed.id => closed, vanished.id => vanished},
      released_claims: %{active.id => release, closed.id => release, vanished.id => release}
    }

    synced =
      IssueSync.sync_polled_issue_state(
        state,
        [active, closed],
        # Verification resolves the absent ticket: it is genuinely closed.
        fn _ -> {:ok, [issue("released-vanished", "done")]} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    # The claim an operator can still recover survives the poll.
    assert %{cause: :rate_limit} = synced.released_claims[active.id]

    # A closed ticket and a ticket confirmed gone are both unrecoverable, so
    # their entries must not keep inflating RELEASED CLAIMS.
    refute Map.has_key?(synced.released_claims, closed.id)
    refute Map.has_key?(synced.released_claims, vanished.id)
  end

  test "keeps a released claim when the ticket's absence is not yet confirmed (#1475)" do
    active = issue("released-active", "in-progress")
    absent = issue("released-absent", "todo")

    release = %{cause: :rate_limit, details: %{}, released_at_ms: 1}

    state = %State{
      last_polled_issues: %{active.id => active, absent.id => absent},
      released_claims: %{absent.id => release}
    }

    synced =
      IssueSync.sync_polled_issue_state(
        state,
        [active],
        # A claim is released because the tracker was failing, which is exactly
        # when a poll comes back partial. Verification cannot confirm the
        # absence here, so the ticket stays pending — and so must its claim.
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert %{cause: :rate_limit} = synced.released_claims[absent.id]
  end
end
