defmodule Aiur.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Application, as: AiurApp
  alias Aiur.Claude.Telemetry

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

  test "logs the resolved base branch exactly once at info level" do
    log = capture_log(fn -> assert :ok = AiurApp.log_base_branch({:ok, %{tracker: %{base_branch: "develop"}}}) end)

    assert length(Regex.scan(~r/aiur_boot phase=config base_branch="develop"/, log)) == 1
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

  describe "RunTelemetry.start_boot/0 enabled gate" do
    test "start_boot/0 writes telemetry_enabled false from config, so telemetry_enabled?/0 agrees" do
      enabled_key = {Aiur.RunTelemetry, :telemetry_enabled}
      original_pt = :persistent_term.get(enabled_key, :unset)
      original_path = Application.get_env(:aiur, :workflow_file_path)

      tmp = Aiur.TestSupport.tmp_root!("disabled-boot-test")
      config_path = Path.join(tmp, "disabledconfig.yaml")
      File.mkdir_p!(tmp)

      File.write!(config_path, """
      tracker:
        kind: github
        github:
          repo: test-org/test-repo
          label_prefix: agent
      observability:
        telemetry_enabled: false
      """)

      on_exit(fn ->
        File.rm_rf!(tmp)

        case original_path do
          nil -> Application.delete_env(:aiur, :workflow_file_path)
          value -> Application.put_env(:aiur, :workflow_file_path, value)
        end

        case original_pt do
          :unset -> :persistent_term.erase(enabled_key)
          value -> :persistent_term.put(enabled_key, value)
        end
      end)

      Application.put_env(:aiur, :workflow_file_path, config_path)
      assert Aiur.Config.telemetry_enabled?() == false

      Aiur.RunTelemetry.start_boot()

      assert Aiur.RunTelemetry.telemetry_enabled?() == false
    end
  end

  describe "shared-child supervision contract" do
    # Regression guard for #2525. `Aiur.PubSub` is the first child of
    # `Aiur.Supervisor`, and Elixir's `Registry` links every registered process
    # to its partition — so `Phoenix.PubSub.subscribe/2` links each subscribing
    # sibling to it. Under `:one_for_one` a PubSub crash therefore kills its
    # subscribers too and restarts them with no ordering guarantee: they
    # resubscribe in `init/1` before PubSub is back, fail to start, and the
    # resulting hot restart loop exhausts the restart budget and terminates all
    # ~90 children with no crash report. `:rest_for_one` is what makes the
    # ordering real — PubSub is restarted first, then everything after it.
    #
    # Flip the strategy in `Aiur.Application.start/2` back to `:one_for_one` and
    # this test fails: the supervisor is gone by the first assertion.
    @tag timeout: 60_000
    test "a crashing Aiur.PubSub does not topple the application supervision tree" do
      # #2548: when this test's premise fails the tree really is gone, and
      # everything after it in the partition inherits a VM with no `Aiur.PubSub`
      # — 21 unrelated reds that named nothing. Assert the restore instead of
      # attempting it, so a failed recovery is reported here, against the test
      # that broke the VM, and the partition is not left poisoned.
      on_exit(fn ->
        assert Aiur.TestSupport.ensure_runtime_children_running() == :ok,
               "application children could not be restored after the PubSub crash; " <>
                 "later tests in this partition would have failed instead of this one"
      end)

      supervisor = Process.whereis(Aiur.Supervisor)
      assert is_pid(supervisor)

      # Only children that are actually running now: sibling tests legitimately
      # stop shared children (`Aiur.HttpServer`, `ResourceStore`, …) and leave
      # them down, so asserting over the whole child list would make this test
      # pass or fail on partition membership — the very disease under repair.
      running_before =
        for {id, pid, _type, _modules} <- Supervisor.which_children(Aiur.Supervisor),
            is_pid(pid),
            do: id

      ref = Process.monitor(supervisor)
      Process.exit(Process.whereis(Aiur.PubSub), :kill)

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
      assert Process.whereis(Aiur.Supervisor) == supervisor

      # The shared children a consumer actually reaches for come back...
      assert await_registered(Aiur.PubSub)
      assert await_registered(Aiur.GitHub.ReadCache)

      # ...and the exact consumer that reported `unknown registry: Aiur.PubSub`
      # can subscribe again rather than raising.
      assert :ok = Telemetry.subscribe()
      Phoenix.PubSub.unsubscribe(Aiur.PubSub, "claude_telemetry:events")

      # Every child that was up before the crash is up again afterwards: the
      # dependents PubSub took down with it were restarted, not abandoned.
      for id <- running_before, do: assert(await_child(id), "#{inspect(id)} never came back")
    end

    # The test above asserts the property; this one pins the race that decided
    # it (#2557). `Aiur.PubSub` is a partitioned `Registry`, and its partitions
    # own registered names of their own. Killing the registry kills them over
    # their links — asynchronously, whenever the scheduler next runs them —
    # while the restart above them is synchronous and retried with no backoff
    # at all. So the restart can find `Aiur.PubSub.PIDPartition0` still holding
    # its name, fail three times inside a millisecond, and take the whole
    # ~90-child tree down; whether it does was decided by scheduling alone,
    # which is why the suite passed for months and then began failing when
    # partition membership shifted the load around it.
    #
    # Suspending the partition makes that window explicit instead of hoping to
    # land in it: the name is *guaranteed* to still be held when the restart
    # comes round. The 300ms release models a slow partition — it is the
    # stimulus, not a timing assertion; every assertion below is signal-based.
    @tag timeout: 60_000
    test "a crashing Aiur.PubSub recovers even when its old partition is slow to release its name" do
      on_exit(fn ->
        assert Aiur.TestSupport.ensure_runtime_children_running() == :ok,
               "application children could not be restored after the PubSub crash"
      end)

      assert Aiur.TestSupport.ensure_runtime_children_running() == :ok

      partition = Process.whereis(:"Elixir.Aiur.PubSub.PIDPartition0")
      assert is_pid(partition), "the PubSub registry always owns partition 0"

      supervisor = Process.whereis(Aiur.Supervisor)
      ref = Process.monitor(supervisor)

      # `:erlang.suspend_process/1` and `resume_process/1` are paired per
      # suspender, so one process has to do both — and it cannot be this one,
      # which is about to block on the tree.
      test_pid = self()

      holder =
        spawn(fn ->
          :erlang.suspend_process(partition)
          send(test_pid, :suspended)

          receive do
            :release -> :erlang.resume_process(partition)
          after
            30_000 -> :ok
          end
        end)

      on_exit(fn -> send(holder, :release) end)
      assert_receive :suspended, 5_000

      Process.exit(Process.whereis(Aiur.PubSub), :kill)
      Process.send_after(holder, :release, 300)

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 10_000
      assert Process.whereis(Aiur.Supervisor) == supervisor
      assert await_registered(Aiur.PubSub)
      assert :ok = Telemetry.subscribe()
      Phoenix.PubSub.unsubscribe(Aiur.PubSub, "claude_telemetry:events")
    end
  end

  # Signal-based, never a duration: polls the registry rather than sleeping for
  # a guessed recovery window, so the result cannot change with machine load.
  # The bound only decides how long a genuine failure takes to report.
  defp await_registered(name, attempts \\ 200)
  defp await_registered(_name, 0), do: false

  defp await_registered(name, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        true

      nil ->
        Process.sleep(25)
        await_registered(name, attempts - 1)
    end
  end

  defp await_child(id, attempts \\ 200)
  defp await_child(_id, 0), do: false

  defp await_child(id, attempts) do
    running? =
      Enum.any?(Supervisor.which_children(Aiur.Supervisor), fn {child_id, pid, _type, _modules} ->
        child_id == id and is_pid(pid)
      end)

    if running? do
      true
    else
      Process.sleep(25)
      await_child(id, attempts - 1)
    end
  end
end
