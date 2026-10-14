defmodule Aiur.Application.ChildrenOrderTest do
  use ExUnit.Case, async: false

  alias Aiur.Application, as: AiurApp

  describe "child_specs/1 start order" do
    defp modules(specs) do
      Enum.map(specs, fn
        mod when is_atom(mod) -> mod
        {mod, _opts} -> mod
        %{id: id} -> id
      end)
    end

    test "current-run membership starts before the orchestrator and reconciles after it" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        membership_store = Enum.find_index(mods, &(&1 == Aiur.CurrentRunMembership.Store))
        orchestrator = Enum.find_index(mods, &(&1 == Aiur.Orchestrator))
        reconciler = Enum.find_index(mods, &(&1 == Aiur.CurrentRunMembership.Reconciler))

        assert membership_store < orchestrator, "membership store must precede Orchestrator for #{inspect(opts)}"
        assert orchestrator < reconciler, "membership reconciler must follow Orchestrator for #{inspect(opts)}"
      end
    end

    test "current-run projections have one runtime owner in every run shape" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: true, headless?: false, dashboard?: false],
            [interactive_cli?: false, headless?: true, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(Keyword.put(opts, :ls_remote_ticker?, true)))
        reconciler = Enum.find_index(mods, &(&1 == Aiur.CurrentRunMembership.Reconciler))
        projection = Enum.find_index(mods, &(&1 == Aiur.CurrentRunProjections))
        merge_ticker = Enum.find_index(mods, &(&1 == Aiur.Events.LsRemoteTicker))

        assert Enum.count(mods, &(&1 == Aiur.CurrentRunProjections)) == 1
        assert projection == reconciler + 1
        assert merge_ticker == projection + 1
      end
    end

    test "provider meters and usage ledger start after the generation owner in every run shape" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        owner = Enum.find_index(mods, &(&1 == Aiur.ProviderAccountGeneration))
        meters = Enum.find_index(mods, &(&1 == Aiur.ProviderMeters.Store))
        ledger = Enum.find_index(mods, &(&1 == Aiur.UsageLedger))
        orchestrator = Enum.find_index(mods, &(&1 == Aiur.Orchestrator))

        assert meters == owner + 1, "provider meters must immediately follow their generation owner for #{inspect(opts)}"
        assert meters < ledger, "provider meters must precede usage ledger for #{inspect(opts)}"
        assert ledger < orchestrator, "usage ledger must precede orchestrator for #{inspect(opts)}"
      end
    end

    test "usage aggregate projection starts after its source ledger in every run shape" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        ledger = Enum.find_index(mods, &(&1 == Aiur.UsageLedger))
        aggregate = Enum.find_index(mods, &(&1 == Aiur.UsageAggregate.Store))
        orchestrator = Enum.find_index(mods, &(&1 == Aiur.Orchestrator))

        assert ledger < aggregate, "usage ledger must precede the aggregate projection for #{inspect(opts)}"
        assert aggregate < orchestrator, "usage aggregate must precede orchestrator for #{inspect(opts)}"
      end
    end

    test "usage compaction coordinator starts after the ledger and aggregate it reads" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        ledger = Enum.find_index(mods, &(&1 == Aiur.UsageLedger))
        aggregate = Enum.find_index(mods, &(&1 == Aiur.UsageAggregate.Store))
        coordinator = Enum.find_index(mods, &(&1 == Aiur.UsageCompaction.Coordinator))

        assert coordinator, "compaction coordinator must be supervised for #{inspect(opts)}"
        assert ledger < coordinator, "compaction must start after the raw ledger for #{inspect(opts)}"
        assert coordinator < aggregate, "compaction must reconcile before the aggregate rebuilds for #{inspect(opts)}"
      end
    end

    test "ticket activity is supervised before the orchestrator in every run shape" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        membership_store = Enum.find_index(mods, &(&1 == Aiur.CurrentRunMembership.Store))
        activity = Enum.find_index(mods, &(&1 == Aiur.TicketActivity))
        orchestrator = Enum.find_index(mods, &(&1 == Aiur.Orchestrator))

        assert membership_store < activity
        assert activity < orchestrator
      end
    end

    test "progress retention starts before ticket activity so the projection can seed at boot" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        retention = Enum.find_index(mods, &(&1 == Aiur.ProgressRetention))
        activity = Enum.find_index(mods, &(&1 == Aiur.TicketActivity))

        assert is_integer(retention), "ProgressRetention must be supervised for #{inspect(opts)}"
        assert retention < activity, "ProgressRetention must precede TicketActivity for #{inspect(opts)}"
      end
    end

    test "Claude telemetry is dashboard-independent and starts before the orchestrator" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        modules = modules(AiurApp.child_specs(opts))
        telemetry = Enum.find_index(modules, &(&1 == Aiur.Claude.Telemetry))
        orchestrator = Enum.find_index(modules, &(&1 == Aiur.Orchestrator))

        assert is_integer(telemetry)
        assert telemetry < orchestrator
      end
    end

    test "Decision metrics starts after the durable Decision service in both shapes" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        decision_store = Enum.find_index(mods, &(&1 == Aiur.DecisionStore))
        metrics_writer = Enum.find_index(mods, &(&1 == Aiur.DecisionMetrics.Writer))
        decision_metrics = Enum.find_index(mods, &(&1 == Aiur.DecisionMetrics))

        assert decision_store < metrics_writer, "DecisionStore must precede metrics for #{inspect(opts)}"
        assert metrics_writer < decision_metrics, "metrics writer must precede collector for #{inspect(opts)}"
      end
    end

    test "Decision expiry starts after its durable store and live-agent source" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        decision_store = Enum.find_index(mods, &(&1 == Aiur.DecisionStore))
        orchestrator = Enum.find_index(mods, &(&1 == Aiur.Orchestrator))
        expiry = Enum.find_index(mods, &(&1 == Aiur.DecisionExpiry))

        assert decision_store < expiry
        assert orchestrator < expiry
      end
    end

    test "recent merge persistence starts before the GitHub-polling orchestrator" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        merge_store = Enum.find_index(mods, &(&1 == Aiur.RecentMergeStore))
        orchestrator = Enum.find_index(mods, &(&1 == Aiur.Orchestrator))

        assert merge_store < orchestrator,
               "RecentMergeStore must precede Orchestrator for #{inspect(opts)}"
      end
    end

    test "branch ref persistence loads before the orchestrator" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        ref_store = Enum.find_index(mods, &(&1 == Aiur.Events.BranchRefStore))
        orchestrator = Enum.find_index(mods, &(&1 == Aiur.Orchestrator))

        assert ref_store < orchestrator,
               "BranchRefStore must precede Orchestrator for #{inspect(opts)}"
      end
    end

    test "telemetry_enabled inserts telemetry supervisor after Exchange and before Publisher in both shapes" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true, telemetry?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false, telemetry?: true]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        exchange = Enum.find_index(mods, &(&1 == Aiur.Events.Exchange))
        telemetry = Enum.find_index(mods, &(&1 == Aiur.RunTelemetry.Supervisor))
        publisher = Enum.find_index(mods, &(&1 == Aiur.Events.Publisher))

        assert exchange < telemetry, "Exchange must precede telemetry for #{inspect(opts)}"
        assert telemetry < publisher, "telemetry must precede Publisher for #{inspect(opts)}"
      end
    end

    test "telemetry disabled removes telemetry supervisor" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true, telemetry?: false],
            [interactive_cli?: false, headless?: true, dashboard?: false, telemetry?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        refute Aiur.RunTelemetry.Supervisor in mods
      end
    end

    test "telemetry supervisor is present by default (no telemetry? opt)" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        assert Aiur.RunTelemetry.Supervisor in mods
      end
    end
  end
end
