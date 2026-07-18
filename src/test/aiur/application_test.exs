defmodule Aiur.ApplicationTest do
  use ExUnit.Case, async: false

  alias Aiur.Application, as: AiurApp

  defmodule SuccessStubDistribution do
    @moduledoc false
    def start!, do: :ok
    def node_name, do: :"stub@127.0.0.1"
  end

  defmodule FailureStubDistribution do
    @moduledoc false
    def start!, do: {:error, :not_distributed}
    def node_name, do: nil
  end

  test "stop/1 is a no-op returning :ok" do
    # `Application.stop/1` is invoked by OTP during application
    # shutdown. There's no cleanup to perform — releases unmount on
    # node halt — so the callback just returns :ok.
    assert :ok = AiurApp.stop(:any_state)
  end

  describe "start_distribution/1" do
    test "logs at info when distribution starts successfully" do
      assert :ok = AiurApp.start_distribution(SuccessStubDistribution)
    end

    test "logs at debug when distribution refuses to start" do
      assert :ok = AiurApp.start_distribution(FailureStubDistribution)
    end
  end

  describe "validate_dashboard_compatibility/2" do
    test "allows no-dashboard when Remote Control is not configured" do
      assert :ok =
               AiurApp.validate_dashboard_compatibility(true,
                 remote_control?: false,
                 routing: %{1 => "codex", 2 => "claude:sonnet"}
               )
    end

    test "rejects no-dashboard when global Remote Control is configured" do
      assert {:error, message} =
               AiurApp.validate_dashboard_compatibility(true,
                 remote_control?: true,
                 routing: %{}
               )

      assert message =~ "--no-dashboard cannot be used with Claude Remote Control"
      assert message =~ "agent.remote_control"
      assert message =~ "Remove --no-dashboard"
    end

    test "rejects no-dashboard when a complexity route forces Remote Control" do
      assert {:error, message} =
               AiurApp.validate_dashboard_compatibility(true,
                 remote_control?: false,
                 routing: %{5 => "claude:opus+remote"}
               )

      assert message =~ "agent.routing +remote"
      assert message =~ "lifecycle hooks require Aiur.HttpServer"
    end

    test "dashboard-enabled launches bypass Remote Control compatibility checks" do
      assert :ok =
               AiurApp.validate_dashboard_compatibility(false,
                 remote_control?: true,
                 routing: %{5 => "claude+remote"}
               )
    end
  end

  describe "child_specs/1 run-shape gating" do
    @terminal_only [
      Aiur.Tmux,
      Aiur.PaneManager,
      Aiur.Opencode.PrewarmSupervisor,
      Aiur.AgentList.App,
      Aiur.AgentList.Input,
      Aiur.LauncherWatchdog,
      Aiur.Opencode.PaneSupervisor
    ]

    @dashboard [AiurWeb.ControlCenterCache, AiurWeb.FinancialData.Supervisor, Aiur.HttpServer]

    # Agent backends kept in headless mode plus core infra both modes need.
    @always [
      Aiur.Orchestrator.TrackedSet,
      Aiur.Orchestrator,
      Aiur.ProcessReaper,
      Aiur.PauseContainment,
      Aiur.AgentResourceGuard,
      Aiur.CoordinationTasks,
      Aiur.BuildOrder.TicketDetailCache,
      Aiur.BuildOrder.GraphProjection,
      Aiur.AppServer.ToolCallLedger,
      Aiur.ProviderAccountGeneration,
      Aiur.ProviderMeters.Store,
      Aiur.UsageLedger,
      Aiur.UsageAggregate.Store,
      Aiur.DecisionMetrics.Writer,
      Aiur.DecisionMetrics,
      Aiur.GitHub.CodeOwners,
      Aiur.RecentMergeStore,
      Aiur.CurrentRunMembership.Store,
      Aiur.CurrentRunMembership.Reconciler,
      Aiur.CurrentRunProjections,
      Aiur.TicketActivity,
      Aiur.Claude.Telemetry,
      Aiur.BuildOrder.TicketHistoryProvider,
      Aiur.Opencode.SessionSupervisor,
      Aiur.Opencode.BridgeSupervisor,
      Aiur.Opencode.TokenRegistry
    ]

    defp modules(specs) do
      Enum.map(specs, fn
        mod when is_atom(mod) -> mod
        {mod, _opts} -> mod
        %{id: id} -> id
      end)
    end

    test "interactive run starts the full UI stack" do
      mods = modules(AiurApp.child_specs(interactive_cli?: true, headless?: false, dashboard?: true))

      for child <- @terminal_only ++ @dashboard ++ @always, do: assert(child in mods, "expected #{inspect(child)}")
    end

    test "headless no-dashboard run keeps the lean background shape" do
      mods = modules(AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false))

      for child <- @terminal_only ++ @dashboard, do: refute(child in mods, "lean background should skip #{inspect(child)}")
      for child <- @always, do: assert(child in mods, "headless still needs #{inspect(child)}")
    end

    test "headless boots measurably fewer children than interactive" do
      interactive = AiurApp.child_specs(interactive_cli?: true, headless?: false, dashboard?: true)
      headless = AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: true)

      assert length(headless) < length(interactive)
    end

    test "headless run starts the dashboard by default without reviving panes" do
      mods = modules(AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: true))

      for child <- @dashboard, do: assert(child in mods, "background should start #{inspect(child)}")
      for child <- @terminal_only, do: refute(child in mods, "headless should skip #{inspect(child)}")
    end

    test "foreground no-dashboard run keeps terminal UI without an HTTP listener" do
      mods = modules(AiurApp.child_specs(interactive_cli?: true, headless?: false, dashboard?: false))

      for child <- @terminal_only, do: assert(child in mods, "foreground should start #{inspect(child)}")
      for child <- @dashboard, do: refute(child in mods, "no-dashboard should skip #{inspect(child)}")
    end

    test "ProcessReaper and PauseContainment start before Task.Supervisor in both shapes" do
      # Load-bearing ordering: children stop in reverse, so the reaper must
      # outlive the runner tasks/ports it sweeps in its terminate/2 backstop.
      # The headless gating must not disturb this.
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        reaper = Enum.find_index(mods, &(&1 == Aiur.ProcessReaper))
        containment = Enum.find_index(mods, &(&1 == Aiur.PauseContainment))
        task_sup = Enum.find_index(mods, &(&1 == Task.Supervisor))
        assert reaper < task_sup, "ProcessReaper must precede Task.Supervisor for #{inspect(opts)}"
        assert containment < task_sup, "PauseContainment must precede Task.Supervisor for #{inspect(opts)}"
      end
    end

    test "ticket history starts after its activity and configured-detail authorities" do
      modules =
        AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false)
        |> modules()

      detail = Enum.find_index(modules, &(&1 == Aiur.BuildOrder.TicketDetailCache))
      activity = Enum.find_index(modules, &(&1 == Aiur.TicketActivity))
      history = Enum.find_index(modules, &(&1 == Aiur.BuildOrder.TicketHistoryProvider))
      orchestrator = Enum.find_index(modules, &(&1 == Aiur.Orchestrator))

      assert detail < history
      assert activity < history
      assert history < orchestrator
    end

    test "ticket-detail cache starts after its task and workflow dependencies" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        task_supervisor = Enum.find_index(mods, &(&1 == Task.Supervisor))
        workflow_store = Enum.find_index(mods, &(&1 == Aiur.WorkflowStore))
        detail_cache = Enum.find_index(mods, &(&1 == Aiur.BuildOrder.TicketDetailCache))

        assert task_supervisor < detail_cache, "Task.Supervisor must precede ticket detail cache for #{inspect(opts)}"
        assert workflow_store < detail_cache, "WorkflowStore must precede ticket detail cache for #{inspect(opts)}"
      end
    end

    test "graph projection starts after its task and workflow dependencies" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        task_supervisor = Enum.find_index(mods, &(&1 == Task.Supervisor))
        workflow_store = Enum.find_index(mods, &(&1 == Aiur.WorkflowStore))
        projection = Enum.find_index(mods, &(&1 == Aiur.BuildOrder.GraphProjection))

        assert task_supervisor < projection, "Task.Supervisor must precede graph projection for #{inspect(opts)}"
        assert workflow_store < projection, "WorkflowStore must precede graph projection for #{inspect(opts)}"
      end
    end

    test "durable workspace ownership reconciles before runner tasks" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        specs = AiurApp.child_specs(opts)
        task_supervisor = Enum.find_index(specs, &match?({Task.Supervisor, _}, &1))

        ownership_registry =
          Enum.find_index(specs, fn
            {Registry, registry_opts} -> Keyword.get(registry_opts, :name) == Aiur.Workspace.Ownership.Registry
            _other -> false
          end)

        ownership_store = Enum.find_index(specs, &(&1 == Aiur.Workspace.Ownership.Store))
        ownership_reconciler = Enum.find_index(specs, &(&1 == Aiur.Workspace.Ownership.Reconciler))

        assert ownership_store < ownership_registry
        assert ownership_registry < ownership_reconciler
        assert ownership_reconciler < task_supervisor
      end
    end

    test "TrackedSet owner starts before Orchestrator in both shapes" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        tracked_set = Enum.find_index(mods, &(&1 == Aiur.Orchestrator.TrackedSet))
        orchestrator = Enum.find_index(mods, &(&1 == Aiur.Orchestrator))
        assert tracked_set < orchestrator, "TrackedSet must precede Orchestrator for #{inspect(opts)}"
      end
    end

    test "the shared test orchestrator starts without a poll cycle" do
      specs = AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false)

      assert {Aiur.Orchestrator, initial_poll?: false} in specs
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
        mods = modules(AiurApp.child_specs(opts))
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

    test "debug mode inserts telemetry after Exchange and before Publisher in both shapes" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true, debug?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false, debug?: true]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        exchange = Enum.find_index(mods, &(&1 == Aiur.Events.Exchange))
        telemetry = Enum.find_index(mods, &(&1 == Aiur.RunTelemetry.Supervisor))
        publisher = Enum.find_index(mods, &(&1 == Aiur.Events.Publisher))

        assert exchange < telemetry, "Exchange must precede telemetry for #{inspect(opts)}"
        assert telemetry < publisher, "telemetry must precede Publisher for #{inspect(opts)}"
      end
    end

    test "non-debug child lists contain no telemetry process" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true, debug?: false],
            [interactive_cli?: false, headless?: true, dashboard?: false, debug?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        refute Aiur.RunTelemetry.Supervisor in mods
      end
    end
  end
end
