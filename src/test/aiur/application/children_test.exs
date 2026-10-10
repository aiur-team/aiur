defmodule Aiur.Application.ChildrenTest do
  use ExUnit.Case, async: false

  alias Aiur.Application, as: AiurApp

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
      Aiur.DecisionDispatchTasks,
      Aiur.BuildOrder.TicketDetailCoordinator,
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
      Aiur.ProgressRetention,
      Aiur.TicketActivity,
      Aiur.Claude.Telemetry,
      Aiur.BuildOrder.TicketHistoryProvider,
      Aiur.DaemonHeartbeatWriter,
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

    test "daemon heartbeat writer is supervised in interactive and headless run shapes" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        assert Aiur.DaemonHeartbeatWriter in modules(AiurApp.child_specs(opts))
      end
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

    test "Tailscale Funnel reconciliation is opt-in and starts after the dashboard" do
      default = AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: true)
      refute Aiur.TailscaleFunnel in modules(default)

      enabled =
        AiurApp.child_specs(
          interactive_cli?: false,
          headless?: true,
          dashboard?: true,
          tailscale_funnel?: true
        )

      enabled_modules = modules(enabled)

      dashboard_index = Enum.find_index(enabled_modules, &(&1 == Aiur.HttpServer))
      funnel_index = Enum.find_index(enabled_modules, &(&1 == Aiur.TailscaleFunnel))

      assert is_integer(dashboard_index)
      assert is_integer(funnel_index)
      assert dashboard_index < funnel_index

      without_dashboard =
        AiurApp.child_specs(
          interactive_cli?: false,
          headless?: true,
          dashboard?: false,
          tailscale_funnel?: true
        )

      refute Aiur.TailscaleFunnel in modules(without_dashboard)
    end

    test "Executor recording is armed on every run, with or without --executor" do
      plain =
        modules(
          AiurApp.child_specs(
            interactive_cli?: false,
            headless?: true,
            dashboard?: false,
            executor_mode?: false,
            recording?: true
          )
        )

      assert Aiur.ExecutorListener in plain, "a run without --executor must still record its wake stream"
      assert Aiur.ExecutorWakeInbox in plain, "a run without --executor must still record its wake stream"
      assert Aiur.Executor.Claims in plain, "consumption is a claim, so the claim store is always present"
      refute Aiur.Executor.Principal in plain, "a run without --executor must not register Executor authority"

      executor =
        modules(
          AiurApp.child_specs(
            interactive_cli?: false,
            headless?: true,
            dashboard?: false,
            executor_mode?: true,
            recording?: true
          )
        )

      assert Aiur.ExecutorListener in executor
      assert Aiur.ExecutorWakeInbox in executor
      assert Aiur.Executor.Claims in executor
      assert Aiur.Executor.Principal in executor, "an --executor run must register its principal claim"
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

    test "decision dispatch coordinator starts after its task supervisor and before DecisionStore" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        task_supervisor = Enum.find_index(mods, &(&1 == Task.Supervisor))
        dispatch_tasks = Enum.find_index(mods, &(&1 == Aiur.DecisionDispatchTasks))
        decision_store = Enum.find_index(mods, &(&1 == Aiur.DecisionStore))

        assert task_supervisor < dispatch_tasks
        assert dispatch_tasks < decision_store
      end
    end

    test "ticket history starts after its activity and configured-detail authorities" do
      modules =
        AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false)
        |> modules()

      detail = Enum.find_index(modules, &(&1 == Aiur.BuildOrder.TicketDetailCoordinator))
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
        detail_cache = Enum.find_index(mods, &(&1 == Aiur.BuildOrder.TicketDetailCoordinator))

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

    test "GitHub quota authority starts before the orchestrator in every run shape" do
      for opts <- [
            [interactive_cli?: true, headless?: false, dashboard?: true],
            [interactive_cli?: false, headless?: true, dashboard?: false]
          ] do
        mods = modules(AiurApp.child_specs(opts))
        quota = Enum.find_index(mods, &(&1 == Aiur.GitHub.Quota))
        orchestrator = Enum.find_index(mods, &(&1 == Aiur.Orchestrator))
        assert quota < orchestrator
      end
    end

    test "the shared test orchestrator starts without a poll cycle" do
      specs = AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false)

      assert {Aiur.Orchestrator, name: Aiur.Orchestrator, initial_poll?: false} in specs
    end

    test "singleton runtime services are explicitly named by their child specs" do
      specs = AiurApp.child_specs(interactive_cli?: true, headless?: false, dashboard?: false)

      assert {Aiur.Tmux, name: Aiur.Tmux} in specs
      assert {Aiur.PaneManager, name: Aiur.PaneManager} in specs
      assert {Aiur.Events.Exchange, name: Aiur.Events.Exchange} in specs
      assert {Aiur.DecisionStore, name: Aiur.DecisionStore} in specs
      assert {Aiur.Orchestrator, name: Aiur.Orchestrator, initial_poll?: false} in specs
    end

    test "the shared test application does not start the remote ref ticker" do
      ticker_enabled? = Application.fetch_env!(:aiur, :ls_remote_ticker_enabled?)

      mods =
        AiurApp.child_specs(
          interactive_cli?: false,
          headless?: true,
          dashboard?: false
        )
        |> modules()

      refute ticker_enabled?
      refute Aiur.Events.LsRemoteTicker in mods
    end

    test "the booted test application supervises BranchRefStore without a ticker writing to it" do
      # The flake this guards (#1745): a live ticker replaces the singleton
      # BranchRefStore's refs mid-test, so a synthetic ref recorded by one test
      # vanishes before that test asserts on it.
      assert is_pid(Process.whereis(Aiur.Events.BranchRefStore))
      refute Process.whereis(Aiur.Events.LsRemoteTicker)
    end

    test "production child specs enable the remote ref ticker by default" do
      ticker_enabled? = Application.fetch_env!(:aiur, :ls_remote_ticker_enabled?)
      on_exit(fn -> Application.put_env(:aiur, :ls_remote_ticker_enabled?, ticker_enabled?) end)
      Application.delete_env(:aiur, :ls_remote_ticker_enabled?)

      mods = modules(AiurApp.child_specs(interactive_cli?: false, headless?: true, dashboard?: false))

      assert Aiur.Events.LsRemoteTicker in mods
    end
  end
end
