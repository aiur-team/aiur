defmodule Aiur.Application.Children do
  @moduledoc """
  The one boot-order authority: the supervision child list for a run shape.
  """

  alias Aiur.BuildOrder.Component, as: BuildOrders
  alias Aiur.Config, as: AiurConfig
  alias Aiur.GitHub.{BlockerProgress, Config}

  @doc """
  Build the supervision children for the given run shape.

  `--bg`/headless runs (`headless?: true`) skip terminal-only work — the
  opencode chat-pane machinery and the whole interactive CLI block (tmux,
  pane manager, opencode pre-warm, agent-list panes). Dashboard supervision
  is independent and remains enabled unless `--no-dashboard` is supplied.
  The agent **backends** that
  actually run agents (session writers, the opencode bridge, token
  registry) are kept so a headless node still does real work; an Executor
  drives it over the control RPC (`status` / `agents` / `message` /
  `pause` / `set max-agents`) instead of attaching to panes.

  Pure so the gating is unit-testable without booting the application —
  pass the resolved booleans and assert which children appear.
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def child_specs(opts) do
    interactive_cli? = Keyword.fetch!(opts, :interactive_cli?)
    headless? = Keyword.fetch!(opts, :headless?)
    dashboard? = Keyword.fetch!(opts, :dashboard?)
    tailscale_funnel? = Keyword.get_lazy(opts, :tailscale_funnel?, &AiurConfig.server_tailscale_funnel?/0)
    telemetry? = Keyword.get(opts, :telemetry?, true)
    executor_mode? = Keyword.get(opts, :executor_mode?, Application.get_env(:aiur, :executor_mode, false))
    ls_remote_ticker? = Keyword.get(opts, :ls_remote_ticker?, Application.get_env(:aiur, :ls_remote_ticker_enabled?, true))

    # Always true for a real run. The unit-test singleton turns it off so the
    # shared app process does not hold a VM-wide inbox and listener that every
    # case would then contend on; cases that exercise recording supervise their
    # own pair against their own isolated state directory.
    recording? = Keyword.get(opts, :recording?, Application.get_env(:aiur, :executor_recording?, true))

    recording_children = recording_children(recording?)

    cli_children =
      if interactive_cli? do
        [
          {Aiur.Tmux, name: Aiur.Tmux},
          {Aiur.PaneManager, name: Aiur.PaneManager},
          Aiur.Opencode.PrewarmSupervisor,
          Aiur.AgentList.App,
          Aiur.AgentList.Input,
          Aiur.LauncherWatchdog
        ]
      else
        []
      end

    [
      # First, ahead of `Aiur.PubSub` itself. `ModeTable` reads no config,
      # subscribes to nothing and calls no sibling — its `init/1` creates one
      # named ETS table and stops — so under `:rest_for_one` every child placed
      # ahead of it declares a dependency it does not have, and pays for it: an
      # ETS table dies with the process that created it, so a crash anywhere in
      # front of `ModeTable` restarted it and silently emptied the entire
      # delivery-mode view (#2531).
      #
      # That is not a bounded cost. Nothing republishes a proven mode on
      # `ModeTable`'s boot — `ModeRegistry` restarts in the same cascade and
      # rebuilds `state.repos` from config as configured-*unproven* — so every
      # webhook-backed repo silently fell back to the 30-second polling TTL and
      # stayed there until a fresh delivery re-proved it; siblings cannot reach it.
      #
      # Going first also means a `ModeTable` crash would now restart the whole
      # tree behind it, which is only acceptable because it has no way to crash:
      # `put/2`, `transport/1` and `delete/1` all run in the *caller's* process
      # against a `:public` table, so the server itself exposes no `handle_call`
      # or `handle_cast` at all — just `init/1` and a catch-all `handle_info/2`.
      Aiur.Webhooks.ModeTable,
      Aiur.Capabilities.Table,
      # `Aiur.PubSub.Boot` wraps `{Phoenix.PubSub, name: Aiur.PubSub}` and waits for a previous incarnation's registry names to be released before starting.
      # Without that wait, a PubSub crash restarts into its own still-registered partitions, fails three times inside a millisecond,
      # and takes this whole supervisor down with it (#2557).
      {Aiur.PubSub.Boot, name: Aiur.PubSub},
      Aiur.AgentPubSub.FleetRefresh,
      {Registry, keys: :unique, name: Aiur.IssueLog.Registry},
      {Registry, keys: :unique, name: Aiur.Opencode.PaneRegistry},
      {Registry, keys: :duplicate, name: Aiur.Opencode.SessionWriterRegistry.Registry},
      {Registry, keys: :unique, name: Aiur.Opencode.SlotRegistry.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Aiur.IssueLog.Supervisor},
      # Before Task.Supervisor: children stop in reverse order, so the
      # reaper outlives the runner tasks/ports whose OS processes it must
      # sweep in its terminate/2 backstop.
      Aiur.ProcessReaper,
      Aiur.PauseContainment,
      Aiur.AgentResourceGuard,
      Aiur.AgentProcessLog,
      Aiur.SaturationSentinel,
      Aiur.BuildGateHoldMonitor,
      Aiur.AppServer.ToolCallLedger,
      Aiur.Workspace.Ownership.Store,
      {Registry, keys: :unique, name: Aiur.Workspace.Ownership.Registry},
      Aiur.Workspace.Ownership.Reconciler,
      {Task.Supervisor, name: Aiur.TaskSupervisor},
      Aiur.AlertFeed.Backfill,
      Aiur.CoordinationTasks,
      Aiur.DecisionDispatchTasks,
      Aiur.WorkflowStore,
      Aiur.RepoBase,
      Aiur.GitHub.AppTokenRefresher,
      # The next three are passive tables a GitHub request consults, started in
      # the order a request touches them: choose a credential, then look for a
      # cached answer, then price and admit what is left. Neither of the first
      # two depends on the other — `ReadCache` is keyed on the request's shape
      # and never asks who is authenticating, and `CredentialHeadroom` is filled
      # from response headers and never asks what was cached — so the order is
      # chosen to be explicable rather than because either would fail otherwise.
      #
      # Owns the per-credential rate-limit table the selector reads. First of the
      # three because selection happens in `default_request_fun`, outside the
      # cache: a request has picked its credential before a lookup is attempted.
      Aiur.GitHub.CredentialHeadroom,
      # The daemon's read-through cache, owning the tables `Aiur.GitHub.Transport`
      # consults on every request. It starts before `Quota` and before anything
      # that polls, because a request issued while its tables do not exist is a
      # request that pays: the lookup degrades to a miss rather than failing, and
      # a miss is the full price. Reads never call this process.
      Aiur.GitHub.ReadCache,
      Aiur.GitHub.Quota,
      # Turns the budget-broker-timeout retry rate into a signal (#2464): a
      # queryable retry event per backoff plus one dwelled degraded alert. The
      # retry path it observes lives in `Aiur.GitHub.LocalHold`; this process
      # owns the sliding-window rate and alert latch.
      Aiur.GitHub.BrokerTimeout,
      Aiur.GitHub.BudgetBroker,
      # The ElevenLabs account credit quota, read on its own schedule. Absent an
      # API key it observes nothing at all, so an unconfigured account costs a
      # boot-time config read and never a request.
      Aiur.ElevenLabs.Quota,
      Aiur.TicketContext.child_specs(:early, opts),
      BuildOrders.child_specs(:early, opts),
      Aiur.Events.IdGenerator,
      {Aiur.Events.Exchange, name: Aiur.Events.Exchange},
      Aiur.Events.BranchRefStore,
      # Restart-durable GitHub state keyed by resource identity. Starts before
      # the Publisher and before anything that polls or receives, so the first
      # delivery of the boot already has somewhere to record that it handled a
      # comment — and so the first poll sweep already has last run's ETags.
      # Owns the open-issue listing the dispatch gate reads as its close signal
      # (#2714). A table owned by a poll writer would die with it.
      Aiur.GitHub.OpenIssueSnapshot,
      Aiur.GitHub.ResourceStore,
      # Carries store changes into the agents' `gh` answer store, so a fact
      # learned for free retires the paid reads of the same resource. Starts
      # after the store because it subscribes to it.
      Aiur.GitHub.AgentCacheBridge,
      if(telemetry?, do: Aiur.RunTelemetry.Supervisor),
      Aiur.Events.Publisher,
      Aiur.Capabilities.Monitor,
      # Per-repo delivery mode. Starts before anything that polls or receives
      # so a repo always has a mode to read; with no configured repos every
      # lookup answers "polling", which is exactly the pre-webhook behavior.
      #
      # The ETS view it publishes into (`Aiur.Webhooks.ModeTable`) is the first
      # child of the whole tree, so the registry always has somewhere to publish
      # and the table outlives every restart the registry can take part in. The
      # reverse is not guaranteed: if the registry crashes, its `state.repos`
      # rebuilds as configured-unproven while the table keeps its old `:webhook`
      # records, so a repo can hold the long TTL until the next sweep
      # republishes. Bounded (the TTL is a backstop, never a freshness claim)
      # and corrected automatically, so it is a note, not a fix.
      Aiur.Webhooks.ModeRegistry,
      Aiur.ProviderAccountGeneration,
      Aiur.ProviderMeters.Store,
      # Reads the store's observations and serves them to consumer surfaces
      # without a binding. Starts after the store so no accepted observation
      # is broadcast before there is anything retaining it.
      Aiur.ProviderMeters.HostObservations,
      Aiur.ProviderMeterProjection,
      # Decides when usage is observed: one baseline after boot, then only
      # while agents are running. Starts after the projection so a baseline
      # observation always has somewhere to land.
      Aiur.ProviderMeterRefresh,
      Aiur.UsageLedger,
      # Owns the one destructive storage seam: retention/compaction of retired
      # raw usage. Starts after the raw ledger it reads but before the aggregate,
      # so its boot reconciliation resolves any in-flight destructive phase into
      # a consistent ledger + compacted-floor state before the aggregate rebuilds
      # over it.
      Aiur.UsageCompaction.Coordinator,
      Aiur.UsageAggregate.Store,
      {Aiur.DecisionStore, name: Aiur.DecisionStore},
      {Aiur.DecisionMetrics.Writer, path: Aiur.DecisionMetrics.metrics_file()},
      Aiur.DecisionMetrics,
      Aiur.RecentMergeStore,
      {Aiur.StartTrigger.ProgressStore, seed: &Aiur.CIApprovalStore.load/0, reader: &BlockerProgress.approval/2, identity: &BlockerProgress.identity/1, repo: &Config.repo/0},
      Aiur.Webhooks.DeliveryLog,
      Aiur.GitHub.CodeOwners,
      {Registry, keys: :unique, name: Aiur.Events.SubscriptionStoreRegistry},
      Aiur.Events.SubscriptionStoreSupervisor,
      Aiur.DecisionAttention,
      Aiur.OperatorWaitLog,
      Aiur.Orchestrator.TrackedSet,
      Aiur.Orchestrator.SnapshotCache,
      Aiur.Orchestrator.SnapshotStore,
      Aiur.Orchestrator.SnapshotPublisher,
      Aiur.CurrentRunMembership.Store,
      # LiveConversation is projection-only: it never replays workspace logs
      # after restart, so a missing key truthfully reports :restart_unknown.
      Aiur.LiveConversation,
      # Durable last-known progress retention. Starts before TicketActivity so
      # the projection can seed from it at boot and cast retains into it.
      Aiur.ProgressRetention,
      Aiur.TicketActivity,
      # Claude telemetry must be available before the Orchestrator starts owned workers.
      Aiur.Claude.Telemetry,
      BuildOrders.child_specs(:history, opts),
      Aiur.TicketContext.child_specs(:late, opts),
      BuildOrders.child_specs(:late, opts),
      {Aiur.OpenTicketSource, poll_on_start: Application.get_env(:aiur, :open_ticket_poll?, dashboard?)},
      # The single view-state cadence, now reconciling only the pack-status
      # writer (OpenTicketSource and AdHocSource are event-sourced and hold no
      # timer). Starts after its sources so its first tick never races boot fill.
      BuildOrders.child_specs(:view_state_sweep, opts),
      {Aiur.Orchestrator, name: Aiur.Orchestrator, initial_poll?: Application.get_env(:aiur, :orchestrator_initial_poll?, true)},
      Aiur.BuildQueue.child(recording?),
      Aiur.DecisionExpiry,
      Aiur.CurrentRunMembership.Reconciler,
      Aiur.CurrentRunProjections,
      maybe_ls_remote_ticker(ls_remote_ticker?),
      Aiur.PRLifecycle.HealthScanner,
      Aiur.PRLifecycle.ReworkRequeue,
      Aiur.ProgressCheckin.Worker,
      Aiur.Executor.TakeoverAlert.Store,
      Aiur.Executor.TakeoverAlert.Monitor,
      Aiur.DaemonHeartbeatWriter,
      Aiur.Logs.Retention,
      # The daemon-resident Executor recording path is armed on EVERY run, with
      # or without `--executor`. Recording is the only part that cannot be added
      # after the fact: a run that did not record leaves an agent arriving later
      # with nothing to replay, and that cost is invisible when it is incurred.
      # `--executor` now governs authority (and Command alerting), not whether
      # anything is written down. These come after the Exchange and the
      # Publisher they subscribe to, so they sit at the end of the always-on
      # block. `Claims` starts first: it arbitrates who may advance the shared
      # cursor the inbox owns.
      recording_children,
      executor_principal_child(recording?, executor_mode?),
      # Dashboard supervision is independent of terminal attachment/headless
      # mode. Aiur.HttpServer retains its own bind and credential guards.
      dashboard_children(dashboard?, Keyword.get(opts, :dashboard_pages?, true), tailscale_funnel?),
      Aiur.Opencode.TokenRegistry,
      Aiur.Opencode.ActiveTurns,
      # Chat-pane machinery — UI-only, never read by a headless run.
      unless(headless?, do: Aiur.Opencode.PaneSupervisor),
      Aiur.Opencode.SessionSupervisor,
      Aiur.Opencode.BridgeSupervisor,
      # Allowed-contributor intake (#2957) feeds the Executor wake path armed
      # above; BuildProgress and its observer run with recording and are
      # last in this `:rest_for_one` list so their restarts can never cascade
      # into the dashboard, the Principal, or the opencode supervisors.
      if(recording?, do: [Aiur.AllowedContributors, BuildOrders.child_specs(:recording, opts)]),
      BuildOrders.child_specs(:final, opts)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(cli_children ++ [Aiur.BackgroundCpu])
  end

  defp maybe_ls_remote_ticker(enabled?) when enabled? in [nil, false], do: nil
  defp maybe_ls_remote_ticker(_enabled?), do: Aiur.Events.LsRemoteTicker

  defp recording_children(true), do: [Aiur.Executor.Claims, Aiur.ExecutorWakeInbox, Aiur.ExecutorListener]
  defp recording_children(false), do: []

  defp executor_principal_child(true, true), do: Aiur.Executor.Principal
  defp executor_principal_child(_recording?, _executor_mode?), do: nil

  defp dashboard_children(dashboard?, dashboard_pages?, tailscale_funnel?) do
    [
      if(dashboard?, do: AiurWeb.ControlCenterCache),
      if(dashboard?, do: AiurWeb.FinancialData.Supervisor),
      if(dashboard?, do: {Aiur.HttpServer, dashboard_pages?: dashboard_pages?}),
      if(dashboard? and tailscale_funnel?, do: Aiur.TailscaleFunnel)
    ]
  end
end
