# MPG-301 addendum: singletons the first census missed

Split out of [MPG-301](MPG-301.md) §1b to keep that page under the file-size gate.

The §1 grep found 27. The inventory test (`test/aiur/project/singleton_inventory_test.exs`) matches every
`name: __MODULE__` / `Keyword.get(opts, :name, __MODULE__)` registration and found 144 more. They are classified here by
the §1 rule. A `per-project` row with ticket `follow-up` is classified but not yet migrated: MPG-305 files one
`needs-triage` ticket for them, and until it lands they keep their module name (correct for a single project). The
classification is by module role, not a line-by-line audit; the follow-up ticket re-checks each row before migrating it.

| # | Module | Owner | Reason | Ticket |
|---|---|---|---|---|
| 1 | `Aiur.AgentList.App` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 2 | `Aiur.AgentList.Input` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 3 | `Aiur.AgentProcessLog` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 4 | `Aiur.AgentResourceGuard` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 5 | `Aiur.AllowedContributors` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 6 | `Aiur.AppServer.ToolCallLedger` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 7 | `Aiur.BackgroundCpu` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 8 | `Aiur.BuildGateHoldMonitor` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 9 | `Aiur.BuildOrder.AdHocSource` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 10 | `Aiur.BuildOrder.EpicOverrides` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 11 | `Aiur.BuildOrder.Estimates` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 12 | `Aiur.BuildOrder.Features.LabelProjection` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 13 | `Aiur.BuildOrder.Features.RootImport` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 14 | `Aiur.BuildOrder.GraphProjection` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 15 | `Aiur.BuildOrder.History` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 16 | `Aiur.BuildOrder.History.Backfill` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 17 | `Aiur.BuildOrder.History.Feeder` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 18 | `Aiur.BuildOrder.History.LabelBackfill` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 19 | `Aiur.BuildOrder.PackStatus` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 20 | `Aiur.BuildOrder.ProgressObserver` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 21 | `Aiur.BuildOrder.TicketDetailCoordinator` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 22 | `Aiur.BuildOrder.TicketHistoryProvider` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 23 | `Aiur.BuildProgress` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 24 | `Aiur.Capabilities.Monitor` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 25 | `Aiur.Capabilities.Table` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 26 | `Aiur.Claude.Telemetry` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 27 | `Aiur.Commands.Routing` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 28 | `Aiur.ControlCall.ReplayStore` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 29 | `Aiur.Conversation.AnchorResolver` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 30 | `Aiur.Conversation.ResolverSupervisor` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 31 | `Aiur.CoordinationTasks` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 32 | `Aiur.CurrentRunMembership.Reconciler` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 33 | `Aiur.CurrentRunMembership.Store` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 34 | `Aiur.CurrentRunProjections` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 35 | `Aiur.DaemonHeartbeatWriter` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 36 | `Aiur.DecisionAttention` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 37 | `Aiur.DecisionDispatchTasks` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 38 | `Aiur.DecisionExpiry` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 39 | `Aiur.DecisionMetrics` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 40 | `Aiur.DecisionMetrics.Writer` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 41 | `Aiur.ElevenLabs.Quota` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 42 | `Aiur.Events.BranchRefStore` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 43 | `Aiur.Events.Export.Exporter` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 44 | `Aiur.Events.IdGenerator` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 45 | `Aiur.Events.LsRemoteTicker` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 46 | `Aiur.Events.Outbound.Delivery` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 47 | `Aiur.Events.Publisher` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 48 | `Aiur.Executor.Claims` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 49 | `Aiur.ExecutorListener` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 50 | `Aiur.Executor.Principal` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 51 | `Aiur.Executor.Session` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 52 | `Aiur.Executor.SessionIngest` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 53 | `Aiur.ExecutorSweep` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 54 | `Aiur.Executor.TakeoverAlert.Monitor` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 55 | `Aiur.Executor.TakeoverAlert.Store` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 56 | `Aiur.Executor.TranscriptIngest` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 57 | `Aiur.ExecutorWakeInbox` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 58 | `Aiur.Experiments.Analyst` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 59 | `Aiur.Experiments.AnalystTrigger` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 60 | `Aiur.Experiments.Auto` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 61 | `Aiur.Experiments.Auto.AiurVersionLine` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 62 | `Aiur.Experiments.Auto.Creator` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 63 | `Aiur.Experiments.Auto.DeployLedger` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 64 | `Aiur.Experiments.Auto.FeatureLine` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 65 | `Aiur.Experiments.Auto.Notifier` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 66 | `Aiur.Experiments.Auto.RepoReleaseLine` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 67 | `Aiur.Experiments.Auto.WindowManager` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 68 | `Aiur.Experiments.Capture` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 69 | `Aiur.Experiments.StatsRunner` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 70 | `Aiur.Experiments.Store` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 71 | `Aiur.Gateway.Liveness` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 72 | `Aiur.GitHub.AgentBudgetSocket` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 73 | `Aiur.GitHub.AgentCacheBridge` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 74 | `Aiur.GitHub.AppTokenRefresher` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 75 | `Aiur.GitHub.BrokerTimeout` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 76 | `Aiur.GitHub.BudgetBroker` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 77 | `Aiur.GitHub.CodeOwners` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 78 | `Aiur.GitHub.CredentialHeadroom` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 79 | `Aiur.GitHub.HoldPressure` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 80 | `Aiur.GitHub.LabelCatalogue` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 81 | `Aiur.GitHub.Quota` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 82 | `Aiur.GitHub.ReadCache` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 83 | `Aiur.GitHub.ResourceStore` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 84 | `Aiur.GitHub.ViewStateSweep` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 85 | `Aiur.Instance.Heartbeat` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 86 | `Aiur.Instance.RepositoryLeader` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 87 | `Aiur.Intent.Hlc` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 88 | `Aiur.Intent.Store` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 89 | `Aiur.Intent.Sync` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 90 | `Aiur.LandingWatch` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 91 | `Aiur.LandingWatch.QuarantineLifter` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 92 | `Aiur.LauncherWatchdog` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 93 | `Aiur.LiveConversation` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 94 | `Aiur.MainWatch` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 95 | `Aiur.Netlify.Usage` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 96 | `Aiur.Opencode.AttachPool` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 97 | `Aiur.Opencode.SlotPolicy` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 98 | `Aiur.OpenTicketSource` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 99 | `Aiur.PauseContainment` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 100 | `Aiur.PeriodicWorker` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 101 | `Aiur.PostDeployChecklist` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 102 | `Aiur.PRLifecycle.HeadVerdictRouter` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 103 | `Aiur.PRLifecycle.HealthScanner` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 104 | `Aiur.PRLifecycle.ReworkRequeue` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 105 | `Aiur.ProcessReaper` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 106 | `Aiur.ProgressCheckin.Worker` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 107 | `Aiur.ProgressRetention` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 108 | `Aiur.ProviderMeterProjection` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 109 | `Aiur.ProviderMeterRefresh` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 110 | `Aiur.ProviderMeters.HostObservations` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 111 | `Aiur.ProviderMeters.Store` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 112 | `Aiur.RecentMergeStore` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 113 | `Aiur.RunTelemetry.FactsCapture` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 114 | `Aiur.RunTelemetry.RepoTimeline` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 115 | `Aiur.RunTelemetry.Sampler` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 116 | `Aiur.RunTelemetry.Supervisor` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 117 | `Aiur.RunTelemetry.UsageCapture` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 118 | `Aiur.RunTelemetry.Writer` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 119 | `Aiur.SaturationSentinel` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 120 | `Aiur.StartTrigger.ProgressStore` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 121 | `Aiur.SupervisionHealth` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 122 | `Aiur.TailscaleFunnel` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 123 | `Aiur.TicketActivity` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 124 | `Aiur.UsageAggregate.Store` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 125 | `Aiur.Usage.Alerts` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 126 | `Aiur.UsageCompaction.Coordinator` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 127 | `Aiur.UsageLedger.Store` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 128 | `AiurWeb.Build.Index` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 129 | `AiurWeb.ControlCenterCache` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 130 | `AiurWeb.DashboardAuth.ChallengeStore` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 131 | `AiurWeb.FinancialData` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 132 | `AiurWeb.FinancialDataAccess.Generation` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 133 | `AiurWeb.FinancialData.ChangeBridge` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 134 | `AiurWeb.FinancialData.SubscriptionAuthority` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 135 | `Aiur.Webhooks.DeliveryLog` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 136 | `Aiur.Webhooks.ModeRegistry` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 137 | `Aiur.Webhooks.ModeTable` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 138 | `AiurWeb.OperatorControlCenter.Analytics.Prewarmer` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 139 | `AiurWeb.Streamdeck.Deck.SettingsSnapshot` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 140 | `AiurWeb.VoiceSessionLimiter` | machine | Serves the whole machine (provider, credential, executor, dashboard or runtime plumbing). | — |
| 141 | `Aiur.Workspace.Ownership.Reconciler` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 142 | `Aiur.Workspace.Ownership.Store` | per-project | Holds ticket-keyed, tracker or workspace state of one repository. | follow-up |
| 143 | `Aiur.Logs.Retention` | machine | Prunes log files on the machine. | — |

| 144 | `Aiur.Ownership.Fence` | machine | Answers the git and gh guards for every agent the daemon runs; one fence per daemon. | MPG-105 |
