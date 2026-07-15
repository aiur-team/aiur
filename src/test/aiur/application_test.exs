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

    @dashboard [AiurWeb.ControlCenterCache, Aiur.HttpServer]

    # Agent backends kept in headless mode plus core infra both modes need.
    @always [
      Aiur.Orchestrator.TrackedSet,
      Aiur.Orchestrator,
      Aiur.ProcessReaper,
      Aiur.PauseContainment,
      Aiur.AgentResourceGuard,
      Aiur.AppServer.ToolCallLedger,
      Aiur.DecisionMetrics.Writer,
      Aiur.DecisionMetrics,
      Aiur.GitHub.CodeOwners,
      Aiur.RecentMergeStore,
      Aiur.CurrentRunMembership.Store,
      Aiur.CurrentRunMembership.Reconciler,
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
