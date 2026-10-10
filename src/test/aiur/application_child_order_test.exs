defmodule Aiur.ApplicationChildOrderTest do
  use ExUnit.Case, async: true

  # Frozen baseline: new children belong after these, never between them.
  @existing_children [
    Aiur.Webhooks.ModeTable,
    Aiur.Capabilities.Table,
    Phoenix.PubSub.Supervisor,
    Aiur.IssueLog.Registry,
    Aiur.Opencode.PaneRegistry,
    Aiur.Opencode.SessionWriterRegistry.Registry,
    Aiur.Opencode.SlotRegistry.Registry,
    Aiur.IssueLog.Supervisor,
    Aiur.ProcessReaper,
    Aiur.PauseContainment,
    Aiur.AgentResourceGuard,
    Aiur.AgentProcessLog,
    Aiur.SaturationSentinel,
    Aiur.BuildGateHoldMonitor,
    Aiur.AppServer.ToolCallLedger,
    Aiur.Workspace.Ownership.Store,
    Aiur.Workspace.Ownership.Registry,
    Aiur.Workspace.Ownership.Reconciler,
    Aiur.TaskSupervisor,
    Aiur.AlertFeed.Backfill,
    Aiur.CoordinationTasks,
    Aiur.DecisionDispatchTasks,
    Aiur.WorkflowStore,
    Aiur.RepoBase,
    Aiur.GitHub.AppTokenRefresher,
    Aiur.GitHub.CredentialHeadroom,
    Aiur.GitHub.ReadCache,
    Aiur.GitHub.Quota,
    Aiur.GitHub.BrokerTimeout,
    Aiur.GitHub.BudgetBroker,
    Aiur.ElevenLabs.Quota,
    Aiur.BuildOrder.TicketDetailCoordinator,
    Aiur.BuildOrder.GraphProjection,
    Aiur.Events.IdGenerator,
    Aiur.Events.Exchange,
    Aiur.Events.BranchRefStore,
    Aiur.GitHub.OpenIssueSnapshot,
    Aiur.GitHub.ResourceStore,
    Aiur.GitHub.AgentCacheBridge,
    Aiur.RunTelemetry.Supervisor,
    Aiur.Events.Publisher,
    Aiur.Capabilities.Monitor,
    Aiur.Webhooks.ModeRegistry,
    Aiur.ProviderAccountGeneration,
    Aiur.ProviderMeters.Store,
    Aiur.ProviderMeters.HostObservations,
    Aiur.ProviderMeterProjection,
    Aiur.ProviderMeterRefresh,
    Aiur.UsageLedger,
    Aiur.UsageCompaction.Coordinator,
    Aiur.UsageAggregate.Store,
    Aiur.DecisionStore,
    Aiur.DecisionMetrics.Writer,
    Aiur.DecisionMetrics,
    Aiur.RecentMergeStore,
    Aiur.Webhooks.DeliveryLog,
    Aiur.GitHub.CodeOwners,
    Aiur.Events.SubscriptionStoreRegistry,
    Aiur.Events.SubscriptionStoreSupervisor,
    Aiur.DecisionAttention,
    Aiur.OperatorWaitLog,
    Aiur.Orchestrator.TrackedSet,
    Aiur.Orchestrator.SnapshotStore,
    Aiur.Orchestrator.SnapshotPublisher,
    Aiur.CurrentRunMembership.Store,
    Aiur.LiveConversation,
    Aiur.ProgressRetention,
    Aiur.TicketActivity,
    Aiur.Claude.Telemetry,
    Aiur.BuildOrder.History,
    Aiur.BuildOrder.History.Backfill,
    Aiur.BuildOrder.Features,
    Aiur.BuildOrder.TicketHistoryProvider,
    Aiur.BuildOrder.AdHocSource,
    Aiur.BuildOrder.PackStatus,
    Aiur.OpenTicketSource,
    Aiur.GitHub.ViewStateSweep,
    Aiur.Orchestrator,
    Aiur.BuildQueue.Server,
    Aiur.DecisionExpiry,
    Aiur.CurrentRunMembership.Reconciler,
    Aiur.CurrentRunProjections,
    Aiur.Events.LsRemoteTicker,
    Aiur.PRLifecycle.HealthScanner,
    Aiur.PRLifecycle.ReworkRequeue,
    Aiur.ProgressCheckin.Worker,
    Aiur.Executor.TakeoverAlert.Store,
    Aiur.Executor.TakeoverAlert.Monitor,
    Aiur.DaemonHeartbeatWriter,
    Aiur.Logs.Retention,
    Aiur.Executor.Claims,
    Aiur.ExecutorWakeInbox,
    Aiur.ExecutorListener,
    Aiur.Executor.Principal,
    AiurWeb.ControlCenterCache,
    AiurWeb.FinancialData.Supervisor,
    Aiur.HttpServer,
    Aiur.TailscaleFunnel,
    Aiur.Opencode.TokenRegistry,
    Aiur.Opencode.ActiveTurns,
    Aiur.Opencode.PaneSupervisor,
    Aiur.Opencode.SessionSupervisor,
    Aiur.Opencode.BridgeSupervisor,
    Aiur.AllowedContributors,
    Aiur.BuildProgress,
    Aiur.BuildOrder.ProgressObserver,
    Aiur.BuildOrder.EpicOverrides,
    Aiur.BuildOrder.Features.RootImport,
    Aiur.Tmux,
    Aiur.PaneManager,
    Aiur.Opencode.PrewarmSupervisor,
    Aiur.AgentList.App,
    Aiur.AgentList.Input,
    Aiur.LauncherWatchdog
  ]

  # Add an ID => reason entry only when a new child must start before existing
  # children. Explain the startup dependency here; do not extend the baseline.
  # Feeder subscribes after History starts and before Backfill can publish completion.
  @early_start_exceptions %{
    Aiur.BuildOrder.History.Feeder => "Subscribe to History before Backfill starts so completion triggers catch-up",
    Aiur.AgentPubSub.FleetRefresh => "Create the subscriber table after PubSub and before channels can register",
    Aiur.Orchestrator.SnapshotCache => "Create the snapshot table before SnapshotStore or SnapshotPublisher can write",
    # The first CI poll and queue reconcile need the seeded progress table before they run.
    Aiur.StartTrigger.ProgressStore => "Seed the ETS table before Orchestrator and BuildQueue start observing PR progress"
  }
  @flags [:interactive_cli?, :headless?, :dashboard?, :tailscale_funnel?, :telemetry?, :executor_mode?, :ls_remote_ticker?, :recording?]

  test "the fully enabled tree retains every existing child in its pinned order" do
    children = child_ids(Keyword.put(Enum.map(@flags, &{&1, true}), :headless?, false))
    assert_order(children, @existing_children)
  end

  test "all startup flag combinations append new children after the existing children" do
    combinations = Enum.reduce(@flags, [[]], fn flag, opts -> for combination <- opts, value <- [false, true], do: [{flag, value} | combination] end)

    for opts <- combinations do
      children = child_ids(opts)
      expected = Enum.filter(@existing_children, &(&1 in children))
      assert_order(children, expected)
    end
  end

  test "a fixture inserted before the Orchestrator fails with append guidance" do
    index = Enum.find_index(@existing_children, &(&1 == Aiur.Orchestrator))
    children = List.insert_at(@existing_children, index, :new_child_fixture)

    assert_raise ExUnit.AssertionError, ~r/Append new children after the existing children/, fn ->
      assert_order(children, @existing_children)
    end
  end

  test "a fixture appended at the end passes" do
    assert_order(@existing_children ++ [:new_child_fixture], @existing_children)
  end

  test "reordering existing children fails" do
    [first, second | rest] = @existing_children

    assert_raise ExUnit.AssertionError, fn ->
      assert_order([second, first | rest], @existing_children)
    end
  end

  test "an early child requires an explicit nonempty dependency reason" do
    children = [:early_child_fixture | @existing_children]
    assert_order(children, @existing_children, %{early_child_fixture: "Existing children depend on its ETS table"})

    assert_raise ExUnit.AssertionError, fn ->
      assert_order(children, @existing_children, %{early_child_fixture: ""})
    end
  end

  defp child_ids(opts) do
    Enum.map(Aiur.Application.child_specs(opts), &Supervisor.child_spec(&1, []).id)
  end

  defp assert_order(children, expected, exceptions \\ @early_start_exceptions) do
    for {id, reason} <- exceptions do
      assert is_binary(reason) and String.trim(reason) != "", "Early-start exception #{inspect(id)} needs a startup dependency reason"
    end

    children = Enum.reject(children, &Map.has_key?(exceptions, &1))

    assert Enum.take(children, length(expected)) == expected,
           "Append new children after the existing children in Aiur.Application.child_specs/1 " <>
             "(including CLI children); a required earlier startup needs a commented @early_start_exceptions entry with its dependency reason."
  end
end
