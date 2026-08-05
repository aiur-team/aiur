defmodule Aiur.OrchestratorPrewarmGateTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator

  describe "prewarm_gate/2" do
    test "dispatches when pre-warm is disabled, regardless of base phase" do
      assert Orchestrator.prewarm_gate(false, :building) == :dispatch
      assert Orchestrator.prewarm_gate(false, :idle) == :dispatch
      assert Orchestrator.prewarm_gate(false, {:error, :boom}) == :dispatch
    end

    test "dispatches once the base is ready" do
      assert Orchestrator.prewarm_gate(true, :ready) == :dispatch
    end

    test "holds dispatch while the base is still warming" do
      for phase <- [:idle, :cloning, :fetching, :building, :checking] do
        assert Orchestrator.prewarm_gate(true, phase) == :hold
      end
    end

    test "falls back to cold dispatch when the base build errored (never hangs)" do
      assert Orchestrator.prewarm_gate(true, {:error, :base_build_failed}) == :dispatch
    end
  end
end
