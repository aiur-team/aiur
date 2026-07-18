defmodule Aiur.Usage.GroupedScopesTest do
  use ExUnit.Case, async: true

  alias Aiur.TestSupport.GroupedScopes, as: Support
  alias Aiur.Usage.GroupedScopes
  alias Aiur.Usage.GroupedScopes.Scope

  defp mixed_run_source do
    Support.source([
      Support.claude_record(1, run_id: "run-A", ticket: 1, tokens: %{input: 1_000_000}, cost: "2.50"),
      Support.claude_record(2, run_id: "run-A", ticket: 1, tokens: %{output: 1_000_000}),
      Support.codex_record(3, run_id: "run-A", ticket: 2, tokens: %{input: 1_000_000}, cost: "1.00"),
      Support.claude_record(4, run_id: "run-A", ticket: 2, tokens: %{cache_creation_input: 500_000})
    ])
  end

  defp project(source, {:ok, scope}, opts \\ []), do: GroupedScopes.project(source, scope, opts)

  defp usd(money), do: Map.get(money, "USD")

  describe "scope typing" do
    test "run-only scope selects the whole run and reconciles every contributor" do
      snap = project(mixed_run_source(), Scope.this_run("run-A"))

      assert snap.scope.kind == :this_run
      assert snap.scope.status == :scoped
      assert snap.tokens == %{input: 2_000_000, output: 1_000_000, cache_creation_input: 500_000}
      assert snap.reconciliation.reconciled?
    end

    test "explicit ticket set includes members and excludes non-members" do
      snap = project(mixed_run_source(), Scope.explicit_ticket_set([Support.identity(1)]))

      # ticket 1 has claude input + output only; ticket 2 (codex + cache) is excluded.
      assert snap.tokens == %{input: 1_000_000, output: 1_000_000}
      assert Decimal.equal?(usd(snap.api_equivalent_estimate.rollup), Decimal.new("18.00"))
    end

    test "intersection requires the run and a member ticket together" do
      snap = project(mixed_run_source(), Scope.intersection("run-A", [Support.identity(2)]))

      # Only ticket 2 under run-A: codex input (unknown price) + claude cache-creation (unknown price).
      assert snap.tokens == %{input: 1_000_000, cache_creation_input: 500_000}
      assert snap.api_equivalent_estimate.rollup == %{}
      assert snap.api_equivalent_estimate.coverage.status == :unknown
    end

    test "bare issue numbers are never scope authority" do
      snap = project(mixed_run_source(), Scope.explicit_ticket_set([1, "1", Support.identity(1)]))
      assert snap.scope.rejected_tickets == 2
    end

    test "pre-membership usage across runs is included for an explicit member" do
      source =
        Support.source([
          Support.claude_record(1, run_id: "run-old", ticket: 7, tokens: %{input: 1_000_000}),
          Support.claude_record(2, run_id: "run-new", ticket: 7, tokens: %{output: 1_000_000})
        ])

      snap = project(source, Scope.explicit_ticket_set([Support.identity(7)]))
      assert snap.tokens == %{input: 1_000_000, output: 1_000_000}
    end

    test "typed repository collision keeps same-numbered tickets in different repos separate" do
      source =
        Support.source([
          Support.claude_record(1, ticket: Support.identity(42), tokens: %{input: 1_000_000}),
          Support.claude_record(2, ticket: Support.identity("acme", "other", 42), tokens: %{output: 1_000_000})
        ])

      snap = project(source, Scope.explicit_ticket_set([Support.identity(42)]))
      # Only the its-everdred/aiur #42 cell is in scope, not acme/other #42.
      assert snap.tokens == %{input: 1_000_000}
    end
  end

  describe "labelled estimates" do
    test "provider-reported and API-equivalent stay separate bases and never combine" do
      snap = project(mixed_run_source(), Scope.this_run("run-A"))

      assert Decimal.equal?(usd(snap.provider_reported_estimate.by_currency), Decimal.new("3.50"))
      assert Decimal.equal?(usd(snap.api_equivalent_estimate.rollup), Decimal.new("18.00"))
      # Distinct top-level bases; no key merges the two.
      refute Map.has_key?(snap.api_equivalent_estimate, :provider_reported)
    end

    test "unretained price partitions surface as explicit unknown coverage, never zero" do
      snap = project(mixed_run_source(), Scope.this_run("run-A"))
      coverage = snap.api_equivalent_estimate.coverage

      assert coverage.known == 2
      assert coverage.unknown == 2
      assert coverage.status == :partial
      assert :unretained_context_tier in coverage.reasons
      assert :unretained_cache_write_duration in coverage.reasons
      # Unknown tokens are visible and attributed, not folded into a zero total.
      assert snap.coverage.unknown_pricing_tokens[:unretained_context_tier] == 1_000_000
      assert snap.coverage.unknown_pricing_tokens[:unretained_cache_write_duration] == 500_000
    end

    test "unlike currencies never combine in provider-reported or by_currency" do
      source =
        Support.source([
          Support.claude_record(1, tokens: %{input: 1_000_000}, cost: "2.00"),
          Support.claude_record(2, tokens: %{input: 1_000_000}, cost: Support.money("3.00", "EUR"))
        ])

      snap = project(source, Scope.this_run("run-1115"))

      assert Decimal.equal?(snap.provider_reported_estimate.by_currency["USD"], Decimal.new("2.00"))
      assert Decimal.equal?(snap.provider_reported_estimate.by_currency["EUR"], Decimal.new("3.00"))
      currencies = snap.contributors.by_currency |> Enum.map(& &1.key) |> Enum.sort()
      assert "EUR" in currencies and "USD" in currencies
    end
  end

  describe "contributor reconciliation" do
    test "every currency roll-up equals the sum of its contributors, both directions" do
      snap = project(mixed_run_source(), Scope.this_run("run-A"))

      for {_label, entries} <- snap.contributors do
        summed =
          entries
          |> Enum.map(&Map.get(&1.api_equivalent.amount, "USD", Decimal.new(0)))
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

        # A dimension that carries API money reconciles exactly to the roll-up.
        if Decimal.gt?(summed, Decimal.new(0)) do
          assert Decimal.equal?(summed, usd(snap.api_equivalent_estimate.rollup))
        end
      end

      assert snap.reconciliation.reconciled?
    end
  end

  describe "tier join keys" do
    test "emits a generation-qualified key for exact known groups only" do
      snap = project(mixed_run_source(), Scope.this_run("run-A"))

      assert %{provider: :claude, backend: :remote_control, account_generation: "generation-c"} in snap.tier_join_keys
      assert %{provider: :codex, backend: :app_server, account_generation: "generation-a"} in snap.tier_join_keys
    end

    test "omits a synthetic key when the account generation or backend is unknown" do
      source =
        Support.raw_source([
          {Support.dims(%{account_generation: nil}), {:token, :input}, 1_000_000},
          {Support.dims(%{backend: :unknown}), {:token, :output}, 1_000_000}
        ])

      snap = project(source, Scope.this_run("run-1115"))
      assert snap.tier_join_keys == []
    end
  end

  describe "deterministic states" do
    test "a healthy scope selecting nothing is known-empty, not a zero total" do
      snap = project(mixed_run_source(), Scope.this_run("run-does-not-exist"))

      assert snap.state == :known_empty
      assert snap.tokens == %{}
      assert snap.api_equivalent_estimate.rollup == %{}
    end

    test "an unavailable projection is distinct from empty" do
      source = Support.source([Support.claude_record(1, tokens: %{input: 1_000_000})], %{health: {:unavailable, :corrupt}})
      snap = project(source, Scope.this_run("run-1115"))

      assert snap.state == :unavailable
      assert snap.reason == :unavailable_projection
      # Coverage keeps a consistent shape so consumers need not branch on state.
      assert snap.coverage.api_equivalent.status == :none
      assert snap.coverage.unknown_pricing_tokens == %{}
    end

    test "a stale snapshot is distinct from partial and empty" do
      source =
        Support.source([Support.claude_record(1, tokens: %{input: 1_000_000})], %{
          freshness: %{status: :stale, projected_position: 0, ledger_position: 5, recovery: :clean}
        })

      assert project(source, Scope.this_run("run-1115")).state == :stale
    end

    test "a missing source is unavailable" do
      assert GroupedScopes.project(nil, elem(Scope.this_run("run-A"), 1)).state == :unavailable
    end
  end

  describe "bounded drill-down" do
    test "pages a contributor dimension deterministically" do
      source =
        Support.source(for n <- 1..5, do: Support.claude_record(n, ticket: n, tokens: %{input: 1_000_000}))

      snap = project(source, Scope.explicit_ticket_set(Enum.map(1..5, &Support.identity/1)))
      page1 = GroupedScopes.drill_down(snap, :by_ticket, limit: 2)

      assert length(page1.items) == 2
      assert page1.total == 5
      assert page1.has_more
      page2 = GroupedScopes.drill_down(snap, :by_ticket, cursor: page1.next_cursor, limit: 2)
      assert page2.cursor == 2
      # Ordering is stable, so pages do not overlap.
      assert MapSet.disjoint?(MapSet.new(page1.items, & &1.key), MapSet.new(page2.items, & &1.key))
    end

    test "limit is clamped and cursor is bounded" do
      snap = project(mixed_run_source(), Scope.this_run("run-A"))
      page = GroupedScopes.drill_down(snap, :by_provider, limit: 10_000)
      assert page.limit == 500
      refute page.has_more
    end
  end

  describe "authority and change detection" do
    test "cache key carries scope and every authority generation" do
      snap = project(mixed_run_source(), Scope.this_run("run-A"))
      {scope, authority} = GroupedScopes.cache_key(snap)

      assert scope.kind == :this_run
      assert authority.schema_version == 1
      assert is_binary(authority.price_table_revision)
    end

    test "a stale generation is rejected rather than relabelled" do
      snap = project(mixed_run_source(), Scope.this_run("run-A"))

      assert GroupedScopes.fresh?(snap, %{
               generation: snap.authority.aggregate_generation,
               source_position: snap.authority.source_position,
               source_generation: snap.authority.source_generation
             })

      refute GroupedScopes.fresh?(snap, %{generation: 999, source_position: 999, source_generation: 999})
    end

    test "changed? distinguishes content and treats no prior snapshot as changed" do
      snap = project(mixed_run_source(), Scope.this_run("run-A"))
      assert GroupedScopes.changed?(nil, snap)
      refute GroupedScopes.changed?(snap, snap)

      other = project(mixed_run_source(), Scope.this_run("run-does-not-exist"))
      assert GroupedScopes.changed?(snap, other)
    end
  end

  describe "restart and retention equivalence" do
    test "a replayed / re-folded source yields an identical snapshot" do
      records = [
        Support.claude_record(1, run_id: "run-A", ticket: 1, tokens: %{input: 1_000_000}, cost: "2.50"),
        Support.codex_record(2, run_id: "run-A", ticket: 2, tokens: %{input: 1_000_000})
      ]

      once = project(Support.source(records), Scope.this_run("run-A"))
      # Duplicate delivery (idempotent replay) must not inflate or change anything.
      replayed = project(Support.source(records ++ records), Scope.this_run("run-A"))

      assert Map.delete(once, :authority) == Map.delete(replayed, :authority)
      assert once.tokens == replayed.tokens
      assert once.reconciliation.reconciled?
    end
  end
end
