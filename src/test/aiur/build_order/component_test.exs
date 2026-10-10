defmodule Aiur.BuildOrder.ComponentTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.Component

  @config_keys [:build_history_backfill_enabled?, :build_order_adhoc_poll?, :build_order_pack_status_poll?, :build_order_root_import_enabled?, :orchestrator_initial_poll?]
  @metrics_path Path.join(System.tmp_dir!(), "aiur-3319-component-metrics.ndjson")
  @opts [interactive_cli?: true, headless?: false, dashboard?: true, tailscale_funnel?: false, recording?: true, executor_mode?: false, ls_remote_ticker?: true]

  # Future regression guard: captured before extraction at d7fad40553019032df0a50354e1a9b559dd7540b, including options.
  @foreground [
    Aiur.Webhooks.ModeTable,
    Aiur.Capabilities.Table,
    {Aiur.PubSub.Boot, [name: Aiur.PubSub]},
    {Registry, [keys: :unique, name: Aiur.IssueLog.Registry]},
    {Registry, [keys: :unique, name: Aiur.Opencode.PaneRegistry]},
    {Registry, [keys: :duplicate, name: Aiur.Opencode.SessionWriterRegistry.Registry]},
    {Registry, [keys: :unique, name: Aiur.Opencode.SlotRegistry.Registry]},
    {DynamicSupervisor, [strategy: :one_for_one, name: Aiur.IssueLog.Supervisor]},
    Aiur.ProcessReaper,
    Aiur.PauseContainment,
    Aiur.AgentResourceGuard,
    Aiur.AgentProcessLog,
    Aiur.SaturationSentinel,
    Aiur.BuildGateHoldMonitor,
    Aiur.AppServer.ToolCallLedger,
    Aiur.Workspace.Ownership.Store,
    {Registry, [keys: :unique, name: Aiur.Workspace.Ownership.Registry]},
    Aiur.Workspace.Ownership.Reconciler,
    {Task.Supervisor, [name: Aiur.TaskSupervisor]},
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
    {Aiur.BuildOrder.TicketDetailCoordinator, [runtime_config?: true]},
    {Aiur.BuildOrder.GraphProjection, [runtime_config?: true]},
    Aiur.Events.IdGenerator,
    {Aiur.Events.Exchange, [name: Aiur.Events.Exchange]},
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
    {Aiur.DecisionStore, [name: Aiur.DecisionStore]},
    {Aiur.DecisionMetrics.Writer, [path: @metrics_path]},
    Aiur.DecisionMetrics,
    Aiur.RecentMergeStore,
    {Aiur.StartTrigger.ProgressStore,
     [seed: &Aiur.CIApprovalStore.load/0, reader: &Aiur.GitHub.BlockerProgress.approval/2, identity: &Aiur.GitHub.BlockerProgress.identity/1, repo: &Aiur.GitHub.Config.repo/0]},
    Aiur.Webhooks.DeliveryLog,
    Aiur.GitHub.CodeOwners,
    {Registry, [keys: :unique, name: Aiur.Events.SubscriptionStoreRegistry]},
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
    Aiur.BuildOrder.History.Feeder,
    {Aiur.BuildOrder.History.Backfill, [enabled?: true]},
    Aiur.BuildOrder.Features,
    {Aiur.BuildOrder.TicketHistoryProvider, [runtime_config?: true]},
    {Aiur.BuildOrder.AdHocSource, [poll_on_start: true]},
    {Aiur.BuildOrder.PackStatus, [poll_on_start: true]},
    {Aiur.OpenTicketSource, [poll_on_start: true]},
    {Aiur.GitHub.ViewStateSweep, [sources: [Aiur.BuildOrder.PackStatus]]},
    {Aiur.Orchestrator, [name: Aiur.Orchestrator, initial_poll?: true]},
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
    AiurWeb.ControlCenterCache,
    AiurWeb.FinancialData.Supervisor,
    Aiur.HttpServer,
    Aiur.Opencode.TokenRegistry,
    Aiur.Opencode.ActiveTurns,
    Aiur.Opencode.PaneSupervisor,
    Aiur.Opencode.SessionSupervisor,
    Aiur.Opencode.BridgeSupervisor,
    Aiur.AllowedContributors,
    Aiur.BuildProgress,
    Aiur.BuildOrder.ProgressObserver,
    Aiur.BuildOrder.EpicOverrides,
    {Aiur.BuildOrder.Features.RootImport, [enabled?: true]},
    {Aiur.Tmux, [name: Aiur.Tmux]},
    {Aiur.PaneManager, [name: Aiur.PaneManager]},
    Aiur.Opencode.PrewarmSupervisor,
    Aiur.AgentList.App,
    Aiur.AgentList.Input,
    Aiur.LauncherWatchdog,
    Aiur.BackgroundCpu,
    Aiur.Experiments.Store
  ]

  setup do
    keys = @config_keys ++ [:open_ticket_poll?, :decision_metrics_path]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:aiur, &1)})
    Enum.each(@config_keys, &Application.put_env(:aiur, &1, true))
    Application.delete_env(:aiur, :open_ticket_poll?)
    Application.put_env(:aiur, :decision_metrics_path, @metrics_path)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:aiur, key, value)
        {key, :error} -> Application.delete_env(:aiur, key)
      end)
    end)
  end

  test "future regression guard: full application child specs retain their order and options" do
    assert Aiur.Application.child_specs(@opts) == @foreground

    without_dashboard =
      @foreground
      |> Enum.reject(&(&1 in [AiurWeb.ControlCenterCache, AiurWeb.FinancialData.Supervisor, Aiur.HttpServer]))
      |> Enum.map(fn
        {Aiur.OpenTicketSource, _} -> {Aiur.OpenTicketSource, poll_on_start: false}
        spec -> spec
      end)

    assert Aiur.Application.child_specs(Keyword.put(@opts, :dashboard?, false)) == without_dashboard
  end

  test "component specs retain configured polling and import switches" do
    Enum.each(@config_keys, &Application.put_env(:aiur, &1, false))
    assert Component.child_specs(:history, []) == [Aiur.BuildOrder.History, Aiur.BuildOrder.History.Feeder, {Aiur.BuildOrder.History.Backfill, enabled?: false}, Aiur.BuildOrder.Features]
    assert Component.child_specs(:late, []) == [{Aiur.BuildOrder.AdHocSource, poll_on_start: false}, {Aiur.BuildOrder.PackStatus, poll_on_start: false}]
    assert Component.child_specs(:final, []) == [Aiur.BuildOrder.EpicOverrides, {Aiur.BuildOrder.Features.RootImport, enabled?: false}]
  end

  test "application composition names only the declared build-order facade" do
    source = File.read!(Path.expand("../../../lib/aiur.ex", __DIR__))
    assert Regex.scan(~r/Aiur\.BuildOrder\.[A-Za-z.]+/, source) == [["Aiur.BuildOrder.Component"]]
    assert source =~ "Aiur.TicketContext.child_specs(:early, opts)"
    assert source =~ "Aiur.TicketContext.child_specs(:late, opts)"
  end
end
