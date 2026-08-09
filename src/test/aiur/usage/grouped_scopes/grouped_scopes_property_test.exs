defmodule Aiur.Usage.GroupedScopesPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.TestSupport.GroupedScopes, as: Support
  alias Aiur.Usage.GroupedScopes
  alias Aiur.Usage.GroupedScopes.Scope

  @runs ["run-A", "run-B"]
  @dimensions [:input, :cached_input, :cache_creation_input, :output, :reasoning_output]

  defp record_spec do
    gen all(
          provider <- member_of([:codex, :claude]),
          run <- member_of(@runs),
          ticket <- integer(1..3),
          dimension <- member_of(@dimensions),
          count <- integer(1..1_000),
          cost <- one_of([constant(nil), map(integer(1..50), &"#{&1}.00")])
        ) do
      %{provider: provider, run: run, ticket: ticket, dimension: dimension, count: count, cost: cost}
    end
  end

  defp build_source(specs) do
    specs
    |> Enum.with_index(1)
    |> Enum.map(fn {spec, position} ->
      opts = [run_id: spec.run, ticket: spec.ticket, tokens: %{spec.dimension => spec.count}, cost: spec.cost]

      case spec.provider do
        :codex -> Support.codex_record(position, opts)
        :claude -> Support.claude_record(position, opts)
      end
    end)
    |> Support.source()
  end

  defp sum_amounts(entries, currency) do
    entries
    |> Enum.map(&Map.get(&1.api_equivalent.amount, currency, Decimal.new(0)))
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  property "every roll-up reconciles to its contributors and unknown pricing never becomes zero" do
    check all(specs <- list_of(record_spec(), min_length: 0, max_length: 12), max_runs: 60) do
      source = build_source(specs)

      for run <- @runs do
        {:ok, scope} = Scope.this_run(run)
        snap = GroupedScopes.project(source, scope)

        # Group and roll-up arithmetic reconciles in both directions.
        assert snap.reconciliation.reconciled?

        rollup = Map.get(snap.api_equivalent_estimate.rollup, "USD", Decimal.new(0))

        # The compatible-currency roll-up equals the sum over any full-dimension
        # contributor set — never more (unknown folded in) nor less.
        assert Decimal.equal?(rollup, sum_amounts(snap.contributors.by_provider, "USD"))
        assert Decimal.equal?(rollup, sum_amounts(snap.contributors.by_ticket, "USD"))

        # Unknown-priced tokens are counted as coverage, never as a monetary zero.
        coverage = snap.api_equivalent_estimate.coverage
        assert coverage.known >= 0 and coverage.unknown >= 0

        if coverage.unknown > 0 do
          assert coverage.status in [:unknown, :partial]
          refute Decimal.negative?(rollup)
        end
      end
    end
  end

  property "run scoping selects exactly the cells belonging to the run" do
    check all(specs <- list_of(record_spec(), min_length: 1, max_length: 12), max_runs: 40) do
      source = build_source(specs)

      for run <- @runs do
        {:ok, scope} = Scope.this_run(run)
        snap = GroupedScopes.project(source, scope)

        expected_tokens =
          specs
          |> Enum.filter(&(&1.run == run))
          |> Enum.reduce(%{}, fn spec, acc -> Map.update(acc, spec.dimension, spec.count, &(&1 + spec.count)) end)

        assert snap.tokens == expected_tokens
      end
    end
  end
end
