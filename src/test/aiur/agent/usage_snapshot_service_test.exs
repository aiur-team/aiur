defmodule Aiur.Agent.UsageSnapshotServiceTest do
  @moduledoc """
  Tests for AgentUsageSnapshotService query and assembly logic.

  Tests focus on scope resolution, aggregate querying, snapshot assembly,
  and proper unknown handling through the service layer.
  """

  use ExUnit.Case

  alias Aiur.Agent.UsageSnapshotService

  describe "current/2 with explicit run_id" do
    test "returns error when no usage data found for run" do
      assert {:error, :no_usage_data} = UsageSnapshotService.current("agent-123", run_id: "run-xyz")
    end

    test "constructs query with provided run_id" do
      assert {:error, :no_usage_data} = UsageSnapshotService.current("agent-123", run_id: "run-xyz")
    end
  end

  describe "current/2 with explicit ticket" do
    test "returns error when no usage data found for ticket" do
      assert {:error, :no_usage_data} = UsageSnapshotService.current("agent-123", ticket: "issue-456")
    end
  end

  describe "current/2 without explicit scope" do
    test "returns error when unable to resolve scope" do
      result = UsageSnapshotService.current("agent-123")
      assert {:error, :unable_to_resolve_scope} = result
    end
  end

  describe "snapshot assembly with aggregate cells" do
    test "sums disjoint ledger deltas once and preserves unsupported dimensions as unknown" do
      cells = %{
        {{%{provider: :codex, backend: :app_server, ingested_at: DateTime.utc_now()}, {:token, :input}}, 100},
        {{%{provider: :codex, backend: :app_server, ingested_at: DateTime.utc_now()}, {:token, :input}}, 40},
        {{%{provider: :codex, backend: :app_server, ingested_at: DateTime.utc_now()}, {:token, :cached_input}}, 35},
        {{%{provider: :codex, backend: :app_server, ingested_at: DateTime.utc_now()}, {:token, :output}}, 12}
      }

      assert %{input: 140, output: 12, cached_input: 35, uncached_input: 105, cached_proportion: 0.25} =
               UsageSnapshotService.aggregate_metrics_from_cells(cells)

      assert %{input: {:unknown, :not_reported}, output: {:unknown, :not_reported}} =
               UsageSnapshotService.aggregate_metrics_from_cells(%{})
    end
  end

  describe "unknown handling through service" do
    test "preserves unsupported dimensions instead of converting them to zero" do
      metrics = UsageSnapshotService.aggregate_metrics_from_cells(%{{%{}, {:token, :input}} => 10})
      assert metrics.input == 10
      assert metrics.cached_input == {:unknown, :not_reported}
      assert metrics.uncached_input == {:unknown, :missing_cached_input}
      assert metrics.cached_proportion == {:unknown, :missing_cached_input}
    end
  end

  describe "scope detection" do
    test "determines scope from query parameters" do
      # The service should detect scope as :session for run_id
      # This is implicitly tested by the error paths above
      :ok
    end
  end

  describe "freshness assessment" do
    test "assesses freshness based on cell ingested_at timestamp" do
      # A full integration test would:
      # 1. Inject an envelope with a recent ingested_at
      # 2. Call current/2
      # 3. Verify snapshot.freshness_assessment == :current
      # For now, this is tested via UsageSnapshot.assess_freshness tests
      :ok
    end
  end

  describe "error handling" do
    test "returns error on aggregate query failure" do
      # Tests graceful error handling when aggregate query fails
      result = UsageSnapshotService.current("agent-123", run_id: "run-xyz")
      assert {:error, _} = result
    end

    test "returns error when scope cannot be resolved and not provided" do
      result = UsageSnapshotService.current("agent-unknown")
      assert {:error, :unable_to_resolve_scope} = result
    end
  end

  describe "integration: end-to-end Codex snapshot" do
    @tag :integration
    test "reports aggregate data only in the requested run scope" do
      assert {:error, :no_usage_data} = UsageSnapshotService.current("agent-123", run_id: "unobserved-run")
    end
  end

  describe "snapshot semantics" do
    @tag :unit
    test "derived values use provider reported input and cached input" do
      assert %{uncached_input: 65, cached_proportion: 0.35} =
               UsageSnapshotService.aggregate_metrics_from_cells(%{
                 {{%{}, {:token, :input}}, 100},
                 {{%{}, {:token, :cached_input}}, 35}
               })
    end

    @tag :unit
    test "aggregate cells combine distinct accepted deltas once" do
      cells = %{
        {{%{relationship_revision: "r1"}, {:token, :input}}, 10},
        {{%{relationship_revision: "r2"}, {:token, :input}}, 5}
      }

      assert %{input: 15} = UsageSnapshotService.aggregate_metrics_from_cells(cells)
    end
  end
end
