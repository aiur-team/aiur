defmodule AiurWeb.DashboardLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.{
    Decision,
    DecisionApi,
    DecisionDispatch,
    DecisionEvent,
    DecisionHistory,
    DecisionMetrics,
    DecisionPubSub,
    DecisionStore,
    Issue,
    TrackerIdentity
  }

  alias Aiur.BuildOrder.Lifecycle
  alias Aiur.DecisionMetrics.Canonical, as: DecisionMetricsCanonical
  alias Aiur.DecisionMetrics.Event, as: DecisionMetricsEvent
  alias Aiur.Events.{Exchange, SubscriptionStore}

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.RecentMerge
  alias Aiur.RecentMergeStore
  alias AiurWeb.{ControlCenterCache, ControlCenterPresenter, DashboardLive, Presenter}
  alias AiurWeb.OperatorControlCenter.{FleetFilters, PayloadLoader, UnitsPresenter}

  @endpoint AiurWeb.Endpoint

  defmodule CountingOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    def snapshot_count(server), do: GenServer.call(server, :snapshot_count)

    @impl true
    def init(opts) do
      {:ok,
       %{
         snapshot: Keyword.fetch!(opts, :snapshot),
         snapshot_count: 0,
         report: Keyword.get(opts, :report)
       }}
    end

    @impl true
    def handle_call(:snapshot, _from, state) do
      snapshot_count = state.snapshot_count + 1
      if is_pid(state.report), do: send(state.report, {:dashboard_payload_loaded, self(), snapshot_count})
      {:reply, state.snapshot, %{state | snapshot_count: snapshot_count}}
    end

    def handle_call(:snapshot_count, _from, state) do
      {:reply, state.snapshot_count, state}
    end
  end

  defmodule CountingDetailStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    def retained_lookup_count(server), do: GenServer.call(server, :retained_lookup_count)

    @impl true
    def init(opts) do
      {:ok, %{store: Keyword.fetch!(opts, :store), retained_lookup_count: 0}}
    end

    @impl true
    def handle_call(:retained_lookup_count, _from, state) do
      {:reply, state.retained_lookup_count, state}
    end

    def handle_call({:retained_lookup, _decision_id} = request, _from, state) do
      reply = GenServer.call(state.store, request)
      {:reply, reply, %{state | retained_lookup_count: state.retained_lookup_count + 1}}
    end

    def handle_call(request, _from, state) do
      {:reply, GenServer.call(state.store, request), state}
    end
  end

  defmodule VersionedDetailStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         overview: Keyword.fetch!(opts, :overview),
         detail: Keyword.fetch!(opts, :detail),
         report: Keyword.fetch!(opts, :report)
       }}
    end

    @impl true
    def handle_call({:recent_decisions, _limit}, _from, state), do: {:reply, [state.overview], state}

    def handle_call({:retained_lookup, decision_id}, _from, %{detail: %{decision_id: decision_id} = detail} = state) do
      {:reply, {:ok, %{decision: detail, health: :writable}}, state}
    end

    def handle_call({:retained_lookup, _decision_id}, _from, state) do
      {:reply, {:ok, %{decision: nil, health: :writable}}, state}
    end

    def handle_call({:replace_detail, detail}, _from, state) do
      {:reply, :ok, %{state | detail: detail}}
    end

    def handle_call(:retained_counts, _from, state) do
      open? = state.detail.decision_status == :open

      counts = %{
        total: 1,
        open: if(open?, do: 1, else: 0),
        blocking: if(open? and state.detail.blocking, do: 1, else: 0)
      }

      {:reply, {:ok, %{counts: counts, health: :writable}}, state}
    end

    def handle_call({:answer, decision_id, payload, opts}, _from, state) do
      send(state.report, {:versioned_detail_answer, decision_id, payload, opts})
      {:reply, {:ok, %{status: :accepted}}, state}
    end

    def handle_call({:revise, decision_id, payload, opts}, _from, state) do
      send(state.report, {:versioned_detail_revision, decision_id, payload, opts})
      {:reply, {:ok, %{status: :accepted}}, state}
    end
  end

  defmodule StaleDetailStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         overview: Keyword.fetch!(opts, :overview),
         detail_status: Keyword.fetch!(opts, :detail_status),
         report: Keyword.fetch!(opts, :report)
       }}
    end

    @impl true
    def handle_call({:recent_decisions, _limit}, _from, state), do: {:reply, [state.overview], state}

    def handle_call({:set_detail_status, detail_status}, _from, state) do
      {:reply, :ok, %{state | detail_status: detail_status}}
    end

    def handle_call({:retained_lookup, _decision_id}, _from, %{detail_status: :unavailable} = state) do
      {:reply, {:error, :store_unavailable}, state}
    end

    def handle_call({:retained_lookup, _decision_id}, _from, %{detail_status: :indeterminate} = state) do
      {:reply, {:ok, %{decision: nil, health: {:corrupt, 1, :test_partial}}}, state}
    end

    def handle_call({:recent_audit_history, _limit}, _from, state) do
      {:reply, %{records: [], contexts: %{}, revisions: %{}}, state}
    end

    def handle_call(:retained_counts, _from, state) do
      {:reply, {:ok, %{counts: %{total: 1, open: 1, blocking: true}, health: :writable}}, state}
    end

    def handle_call({:answer, decision_id, payload, opts}, _from, state) do
      send(state.report, {:stale_detail_answer, decision_id, payload, opts})
      {:reply, {:ok, %{status: :accepted}}, state}
    end

    def handle_call({:revise, decision_id, payload, opts}, _from, state) do
      send(state.report, {:stale_detail_revision, decision_id, payload, opts})
      {:reply, {:ok, %{status: :accepted}}, state}
    end

    def handle_call(_request, _from, state), do: {:reply, {:error, :store_unavailable}, state}
  end

  defmodule QueueOrchestrator do
    use GenServer

    alias Aiur.Orchestrator.OperatorMessages
    alias Aiur.Orchestrator.StatusReport

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :state)}

    @impl true
    def handle_call(:snapshot, _from, state), do: StatusReport.snapshot(state)

    def handle_call({:send_correlated_operator_message, issue_identifier, payload}, _from, state) do
      OperatorMessages.send_correlated_operator_message_call(state, issue_identifier, payload)
    end

    def handle_call({:claim_next_queue_item, issue_identifier}, _from, state) do
      OperatorMessages.claim_next_queue_item_call(state, issue_identifier)
    end
  end

  defmodule RejectingDecisionStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      {:ok, %{decision: Keyword.fetch!(opts, :decision), report: Keyword.fetch!(opts, :report)}}
    end

    @impl true
    def handle_call(:health, _from, state), do: {:reply, :writable, state}
    def handle_call({:get, decision_id}, _from, %{decision: %{decision_id: decision_id} = decision} = state), do: {:reply, {:ok, decision}, state}
    def handle_call({:get, _decision_id}, _from, state), do: {:reply, {:error, :not_found}, state}

    def handle_call(
          {:retained_lookup, decision_id},
          _from,
          %{decision: %{decision_id: decision_id} = decision} = state
        ),
        do: {:reply, {:ok, %{decision: decision, health: :writable}}, state}

    def handle_call({:retained_lookup, _decision_id}, _from, state),
      do: {:reply, {:ok, %{decision: nil, health: :writable}}, state}

    def handle_call(:list, _from, state), do: {:reply, [state.decision], state}
    def handle_call({:recent_decisions, _limit}, _from, state), do: {:reply, [state.decision], state}
    def handle_call(:all_history, _from, state), do: {:reply, %{state.decision.decision_id => [state.decision]}, state}

    def handle_call(:all_audit_history, _from, state) do
      {:reply, %{state.decision.decision_id => [state.decision]}, state}
    end

    def handle_call(:retained_counts, _from, state) do
      {:reply, retained_counts(state.decision), state}
    end

    def handle_call({:recent_audit_history, _limit}, _from, state) do
      {:reply, %{records: [state.decision], contexts: %{}, revisions: %{}}, state}
    end

    def handle_call({:answer, decision_id, payload, opts}, _from, state) do
      send(state.report, {:dashboard_answer_attempt, decision_id, payload, opts})
      {:reply, {:error, {:conflict, {:stale_version, 1, 2}}}, state}
    end

    defp retained_counts(decision) do
      open? = decision.decision_status == :open

      {:ok,
       %{
         counts: %{
           total: 1,
           open: if(open?, do: 1, else: 0),
           blocking: if(open? and decision.blocking, do: 1, else: 0)
         },
         health: :writable
       }}
    end
  end

  defmodule RejectingRevisionStore do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      {:ok, %{decision: Keyword.fetch!(opts, :decision), report: Keyword.fetch!(opts, :report)}}
    end

    @impl true
    def handle_call(:health, _from, state), do: {:reply, :writable, state}
    def handle_call({:get, decision_id}, _from, %{decision: %{decision_id: decision_id} = decision} = state), do: {:reply, {:ok, decision}, state}
    def handle_call({:get, _decision_id}, _from, state), do: {:reply, {:error, :not_found}, state}

    def handle_call(
          {:retained_lookup, decision_id},
          _from,
          %{decision: %{decision_id: decision_id} = decision} = state
        ),
        do: {:reply, {:ok, %{decision: decision, health: :writable}}, state}

    def handle_call({:retained_lookup, _decision_id}, _from, state),
      do: {:reply, {:ok, %{decision: nil, health: :writable}}, state}

    def handle_call(:list, _from, state), do: {:reply, [state.decision], state}
    def handle_call({:recent_decisions, _limit}, _from, state), do: {:reply, [state.decision], state}
    def handle_call(:all_history, _from, state), do: {:reply, %{state.decision.decision_id => [state.decision]}, state}

    def handle_call(:all_audit_history, _from, state) do
      {:reply, %{state.decision.decision_id => [state.decision]}, state}
    end

    def handle_call(:retained_counts, _from, state) do
      {:reply, retained_counts(state.decision), state}
    end

    def handle_call({:recent_audit_history, _limit}, _from, state) do
      {:reply, %{records: [state.decision], contexts: %{}, revisions: %{}}, state}
    end

    def handle_call({:revise, decision_id, payload, opts}, _from, state) do
      send(state.report, {:dashboard_revision_attempt, decision_id, payload, opts})
      {:reply, {:error, {:conflict, {:stale_action, "new-active-action"}}}, state}
    end

    defp retained_counts(decision) do
      open? = decision.decision_status == :open

      {:ok,
       %{
         counts: %{
           total: 1,
           open: if(open?, do: 1, else: 0),
           blocking: if(open? and decision.blocking, do: 1, else: 0)
         },
         health: :writable
       }}
    end
  end

  defp render_payload(fleet_payload, opts \\ []) do
    payload =
      Keyword.get_lazy(opts, :payload, fn ->
        ControlCenterPresenter.state_payload(
          :unused,
          1,
          fleet_fun: fn -> fleet_payload end,
          decisions_fun: fn -> [] end
        )
      end)

    selected_decision_id = Keyword.get(opts, :selected_decision_id)
    selected_decision = Enum.find(payload.decisions, &(&1.decision_id == selected_decision_id))

    assigns = %{
      payload: payload,
      now: DateTime.utc_now(),
      agent_log_modal: nil,
      drafts: %{},
      chat_errors: %{},
      decision_actions: %{},
      writable: false,
      live_action: Keyword.get(opts, :live_action, :index),
      decision_filter: :all,
      fleet_filters: FleetFilters.default(),
      selected_decision_id: selected_decision_id,
      selected_decision: selected_decision,
      selected_decision_status: Keyword.get(opts, :selected_decision_status, if(selected_decision, do: :available, else: :not_found)),
      selected_decision_health: Keyword.get(opts, :selected_decision_health)
    }

    assigns
    |> DashboardLive.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  test "does not present untyped status rows as a healthy Units catalog" do
    orchestrator_name = Module.concat(__MODULE__, :RenderOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    ci_wait_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-900",
      issue: %Issue{id: "issue-ci-wait", identifier: "MT-900", state: "ci-wait", title: "Row MT-900"},
      worker_host: nil,
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :paused},
      session_id: "thread-MT-900",
      codex_app_server_pid: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now(),
      last_codex_timestamp: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      paused_reason: :ci_wait
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{"issue-ci-wait" => ci_wait_entry},
          retry_attempts: %{
            "issue-retry" => %{
              attempt: 2,
              timer_ref: nil,
              due_at_ms: System.monotonic_time(:millisecond) + 5_000,
              identifier: "MT-902",
              error: "temporary failure"
            }
          },
          ci_lifecycle: %{
            state.ci_lifecycle
            | poll_cache: %{"MT-900" => %{decision: :pending, pr_number: 77, head_sha: "deadbeef"}}
          },
          last_polled_issues: %{
            "issue-ci-wait" => %Issue{id: "issue-ci-wait", identifier: "MT-900", state: "ci-wait"},
            "issue-idle" => %Issue{id: "issue-idle", identifier: "MT-901", state: "human-review", title: "Idle review"},
            "issue-retry" => %Issue{id: "issue-retry", identifier: "MT-902", state: "rework", title: "Retrying"}
          }
      }
    end)

    payload = Presenter.state_payload(orchestrator_name, 1_000)
    html = render_payload(payload)

    assert html =~ "Units unavailable"
    assert html =~ "Units catalog is unavailable"
    refute html =~ "MT-900"
    refute html =~ "Idle review"
  end

  test "renders payload-aware document navigation and owner-aware Build Order navigation" do
    fleet_payload = %{
      generated_at: "2026-07-12T12:00:00Z",
      counts: %{running: 0, retrying: 0, idle: 0},
      running: [],
      retrying: [],
      idle: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    unavailable_units = render_payload(fleet_payload)

    available_payload =
      Map.put(fleet_payload, :analytics, %{
        available?: true,
        path: "/analytics",
        message: "Open the separate durable telemetry report."
      })

    available_units = render_payload(available_payload)
    commands = render_payload(available_payload, live_action: :decision)

    assert length(Floki.find(Floki.parse_document!(unavailable_units), ~s(nav[aria-label^="Control Center"]))) == 2
    assert length(Floki.find(Floki.parse_document!(unavailable_units), ~s(a[aria-current="page"]))) == 2
    assert unavailable_units =~ ~s(<h1 id="route-title">Units</h1>)
    refute unavailable_units =~ ~s(href="/analytics")
    assert unavailable_units =~ ~s(href="/build-orders")
    assert unavailable_units =~ ~s(data-phx-link="redirect")
    assert unavailable_units =~ "Telemetry analytics are unavailable."
    assert length(Floki.find(Floki.parse_document!(unavailable_units), ~s([aria-disabled="true"]))) == 2

    assert available_units =~ ~s(href="/analytics")
    assert Floki.find(Floki.parse_document!(available_units), ~s([aria-disabled="true"])) == []

    assert commands =~ ~s(<h1 id="route-title">Commands</h1>)
    assert length(Floki.find(Floki.parse_document!(commands), ~s(a[aria-current="page"]))) == 2
  end

  test "renders the approved decision surface with a stable escaped deep link" do
    fleet_payload = %{
      generated_at: "2026-07-12T12:00:00Z",
      counts: %{running: 0, retrying: 0, idle: 0},
      running: [],
      retrying: [],
      idle: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    decision = %{
      decision_id: "dec-safe-link",
      version: 1,
      ticket: %{identifier: "AIUR-987", title: "Operator Control Center", url: "https://example.test/issues/987"},
      source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-987"},
      kind: "architecture",
      authority: :human_required,
      urgency: :critical,
      blocking: true,
      reversibility: :reversible,
      question: "Should the component split ship?",
      context: %{short: "Use the approved design", long_markdown: "**safe markdown** <script>alert('no')</script>"},
      options: [],
      recommendation: nil,
      consequence_of_delay: "The agent remains paused.",
      artifacts: [],
      created_at: ~U[2026-07-12 12:00:00Z],
      source_created_at: nil,
      decision_status: :open,
      delivery_status: :not_dispatched,
      answer: nil,
      dispatch_attempts: [],
      acknowledgement: nil,
      resolution: nil,
      retryable: false,
      failure_reason: nil,
      lifecycle: :recorded
    }

    payload =
      fleet_payload
      |> ControlCenterPresenter.compose([], [], %{
        merges: [],
        health: :ready,
        reconciliation: %{status: :complete, partial?: false}
      })
      |> Map.put(:decisions, [decision])
      |> Map.put(:overview, %{
        blocking_decisions: 1,
        running: 0,
        queued_or_retrying: 0,
        recent_repository_merges: 0
      })

    inbox_html = render_payload(fleet_payload, payload: payload, live_action: :decisions)

    detail_html =
      render_payload(fleet_payload,
        payload: payload,
        live_action: :decision,
        selected_decision_id: decision.decision_id
      )

    assert inbox_html =~ ~s(src="/aiur-logo.png")
    assert inbox_html =~ ~s(href="/decisions/dec-safe-link")
    assert inbox_html =~ "Commands inbox"
    refute inbox_html =~ ~s(id="recent-title")
    assert detail_html =~ "Recorded"
    assert detail_html =~ "Dispatch pending"
    assert detail_html =~ "The agent remains paused."
    assert detail_html =~ "&lt;script&gt;alert(&#39;no&#39;)&lt;/script&gt;"
    refute detail_html =~ "<script>alert('no')</script>"
    assert detail_html =~ "Read-only mode · Command mutation controls are hidden."
  end

  test "renders canonical retained counts and warns when retained detail data is partial" do
    fleet_payload = %{
      generated_at: "2026-07-12T12:00:00Z",
      counts: %{running: 0, retrying: 0, idle: 0},
      running: [],
      retrying: [],
      idle: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    decision = dashboard_decision("dec-partial-retained")

    merge_snapshot = %{
      merges: [],
      health: :ready,
      reconciliation: %{status: :complete, partial?: false}
    }

    payload =
      fleet_payload
      |> ControlCenterPresenter.compose([decision], [], merge_snapshot)
      |> Map.put(:retained_counts, %{
        open: 73,
        blocking: 4,
        scope: %{kind: :retained, label: "All retained decisions"},
        health: %{status: :partial, partial?: true, label: "Partial retained Decision data"}
      })

    html =
      render_payload(fleet_payload,
        payload: payload,
        live_action: :decision,
        selected_decision_id: decision.decision_id,
        selected_decision_health: %{status: :partial, partial?: true}
      )

    assert html =~ "4 Commands are blocking agents"
    assert html =~ "73 awaiting input in total"
    assert html =~ "Partial retained Command counts"
    assert html =~ "Partial retained Command data"
  end

  test "does not report a missing Decision as absent when retained replay is partial" do
    fleet_payload = %{
      generated_at: "2026-07-12T12:00:00Z",
      counts: %{running: 0, retrying: 0, idle: 0},
      running: [],
      retrying: [],
      idle: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    payload =
      ControlCenterPresenter.state_payload(
        :unused,
        1,
        fleet_fun: fn -> fleet_payload end,
        decisions_fun: fn -> [] end
      )

    html =
      render_payload(fleet_payload,
        payload: payload,
        live_action: :decision,
        selected_decision_id: "dec-maybe-retained",
        selected_decision_status: :indeterminate,
        selected_decision_health: %{status: :partial, partial?: true}
      )

    assert html =~ "Command presence unknown"
    assert html =~ "may exist beyond the validated audit prefix"
    refute html =~ "No retained Command matches"
    refute html =~ "This detail was recovered from the validated audit prefix"
  end

  test "renders durable decision history, honest merge provenance, and the analytics link during a snapshot outage" do
    history = [
      history_entry("dec-human", :human_operator, "Executor", "<script>alert('decision')</script>"),
      history_entry("dec-supervisor", :supervising_agent, "Supervising agent", "Approve the fallback?")
    ]

    assert {:ok, merge} =
             RecentMerge.from_github_event(merged_event(),
               live?: true,
               run_id: "run-observer-123456789",
               now: ~U[2026-07-12 18:01:00Z]
             )

    telemetry_path = Path.expand("../../fixtures/run_telemetry/session-a/telemetry.ndjson", __DIR__)
    assert File.regular?(telemetry_path), telemetry_path

    payload =
      Presenter.state_payload(Module.concat(__MODULE__, :MissingHistoryOrchestrator), 5,
        decision_history_fun: fn -> history end,
        recent_merge_snapshot_fun: fn ->
          %{
            merges: [merge],
            health: :writable,
            reconciliation: %{status: :partial, partial?: true, pages_fetched: 5}
          }
        end,
        telemetry_file_fun: fn -> telemetry_path end
      )

    assert payload.analytics.available?, inspect(payload.analytics)
    html = render_payload(payload)

    assert html =~ "Snapshot unavailable"
    refute html =~ "Merged this run"
    refute html =~ "from the current run"
    assert html =~ "Command history"
    assert html =~ "Executor"
    assert html =~ "Supervising agent"
    assert html =~ "&lt;script&gt;alert"
    refute html =~ "<script>alert"
    assert html =~ "Recent repository merges"
    assert html =~ "Observed live"
    assert html =~ "Observer run run-observer"
    assert html =~ "No ticket attribution"
    assert html =~ "5-page cap"
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute html =~ "<img src=x"
    assert html =~ ~s(href="/analytics")
    assert html =~ "Open analytics report"
  end

  test "bounds each payload signal burst across open dashboards" do
    orchestrator_name = Module.concat(__MODULE__, :CountingOrchestratorInstance)
    test_process = self()

    start_supervised!(
      {CountingOrchestrator,
       name: orchestrator_name,
       snapshot: %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}
    )

    reload_timer = fn destination, message, delay_ms ->
      send(test_process, {:payload_reload_scheduled, destination, message, delay_ms})
      make_ref()
    end

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_reload_timer: reload_timer
    )

    {:ok, view, _html} = live(build_conn(), "/")
    {:ok, second_view, _html} = live(build_conn(), "/")
    views = [view, second_view]
    cache = AiurWeb.Endpoint.config(:control_center_cache)

    assert_bounded_reload_burst(views, List.duplicate(:observability_updated, 25), cache, orchestrator_name)

    decision_messages =
      Enum.map(1..25, fn version -> {:decision_changed, "decision-#{version}", version} end)

    assert_bounded_reload_burst(views, decision_messages, cache, orchestrator_name)
    assert_bounded_reload_burst(views, List.duplicate(:decision_metrics_changed, 25), cache, orchestrator_name)

    membership_messages =
      List.duplicate({:current_run_membership_changed, %{generation: 2}}, 25)

    assert_bounded_reload_burst(views, membership_messages, cache, orchestrator_name, false)
  end

  describe "current-run summary" do
    test "renders a pushed summary with a bounded announcement and no protected fields" do
      view = start_run_summary_dashboard()
      html = push_summary(view, healthy_summary_snapshot(live: 3))

      assert html =~ "Current run"
      assert html =~ "Weighted progress"
      assert html =~ ~s(role="progressbar")
      assert html =~ ~s(aria-valuenow="60")
      assert html =~ "60% complete (exact)"
      assert html =~ "Health: Healthy"
      assert html =~ ~s(id="run-summary-status")
      assert html =~ "3 live"

      # Scope the protected-field check to the summary card so page-level CSRF
      # and LiveView session tokens do not trip the assertion.
      card = view |> element("section.run-summary-card") |> render() |> String.downcase()

      for term <- ["cost", "token", "provider", "quota", "credit", "$"] do
        refute String.contains?(card, term), "expected no protected term #{inspect(term)}"
      end
    end

    test "coalesces a burst of summary updates into a single scheduled flush" do
      view = start_run_summary_dashboard()

      for _ <- 1..25 do
        send(view.pid, {:current_run_summary_changed, healthy_summary_snapshot(live: 9)})
      end

      :sys.get_state(view.pid)

      assert_receive {:run_summary_flush_scheduled, pid, :flush_run_summary, delay_ms}, 0
      assert pid == view.pid
      assert delay_ms > 0
      refute_receive {:run_summary_flush_scheduled, _pid, :flush_run_summary, _delay}, 0

      send(view.pid, :flush_run_summary)
      assert render(view) =~ "9 live"
    end

    test "retains the last known-good summary across an unavailable same-run update" do
      view = start_run_summary_dashboard()

      assert push_summary(view, healthy_summary_snapshot(live: 3)) =~ "60% complete (exact)"

      stale_html = push_summary(view, unavailable_same_run_snapshot())

      assert stale_html =~ "Stale summary"
      assert stale_html =~ "60% complete (exact)"
      assert stale_html =~ "3 live"
      assert stale_html =~ "Health: Unavailable"
      # Never fall back to a zeroed/empty summary for the retained run.
      refute stale_html =~ "zero eligible weight"
      refute stale_html =~ "0 live"
    end

    test "adopts a new run generation instead of showing the prior run as current" do
      view = start_run_summary_dashboard()

      assert push_summary(view, healthy_summary_snapshot(live: 3, run_id: "run-1")) =~ "60% complete (exact)"

      new_html = push_summary(view, healthy_summary_snapshot(live: 8, run_id: "run-2", exact: {3, 10}))

      assert new_html =~ "30% complete (exact)"
      assert new_html =~ ~s(aria-valuenow="30")
    end
  end

  describe "current-run outcomes (DASH-034)" do
    test "renders the Finished this run region on the Units destination with the real analytics route" do
      view = start_outcomes_dashboard()
      html = push_outcomes(view, healthy_outcomes_snapshot(numbers: [42, 7]))

      assert html =~ "Finished this run"
      assert html =~ ~s(id="current-run-outcomes")
      assert html =~ "PR #42"
      assert html =~ "its-everdred/aiur #42"
      assert html =~ ~s(href="https://github.com/its-everdred/aiur/pull/42")
      # The region consumes the shared analytics contract; it never hardcodes the
      # prototype's aiur.team destination. (Route availability is telemetry-driven
      # and exercised in the component test.)
      refute html =~ "aiur.team"
      # The global RecentMerge audit remains a distinct, reachable scope.
      assert html =~ "Recent repository merges"
    end

    test "coalesces a burst of outcome updates into a single scheduled flush" do
      view = start_outcomes_dashboard()

      for _ <- 1..25 do
        send(view.pid, {:current_run_outcome_snapshot_changed, healthy_outcomes_snapshot(numbers: [1])})
      end

      :sys.get_state(view.pid)

      assert_receive {:outcomes_flush_scheduled, pid, :flush_current_run_outcomes, delay_ms}, 0
      assert pid == view.pid
      assert delay_ms > 0
      refute_receive {:outcomes_flush_scheduled, _pid, :flush_current_run_outcomes, _delay}, 0

      send(view.pid, :flush_current_run_outcomes)
      assert render(view) =~ "PR #1"
    end

    test "retains the last validated outcomes across an unavailable same-run update" do
      view = start_outcomes_dashboard()

      assert push_outcomes(view, healthy_outcomes_snapshot(numbers: [11], run_id: "run-1")) =~ "PR #11"

      stale_html = push_outcomes(view, unavailable_same_run_outcomes_snapshot("run-1"))

      assert stale_html =~ "Stale outcomes"
      assert stale_html =~ "PR #11"
      # Never fall back to a confident empty claim for the retained run.
      refute stale_html =~ "No repository merges have finished this run yet"
    end

    test "adopts a new run, dropping prior-run cards under the current heading" do
      view = start_outcomes_dashboard()

      assert push_outcomes(view, healthy_outcomes_snapshot(numbers: [11], run_id: "run-1")) =~ "PR #11"

      new_html = push_outcomes(view, healthy_outcomes_snapshot(numbers: [22], run_id: "run-2"))

      assert new_html =~ "PR #22"
      refute new_html =~ "PR #11"
    end
  end

  test "optional unauthenticated LiveView state, HTML, diffs, and logs contain no financial sentinels" do
    orchestrator_name = Module.concat(__MODULE__, :FinancialBoundaryOrchestrator)
    sentinel = "acct-plan-quota-reset-financial-sentinel"
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    start_supervised!(
      {CountingOrchestrator,
       name: orchestrator_name,
       snapshot: %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{
           input_tokens: sentinel,
           output_tokens: sentinel,
           total_tokens: sentinel,
           seconds_running: 41
         },
         rate_limits: %{
           provider: sentinel,
           plan: sentinel,
           quota: sentinel,
           reset_at: sentinel,
           last_known_good: sentinel
         }
       }}
    )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      dashboard_auth_required: false
    )

    test_process = self()

    log =
      capture_log(fn ->
        send(test_process, {:financial_boundary_live, live(build_conn(), "/")})
      end)

    assert_receive {:financial_boundary_live, {:ok, view, html}}, 2_000
    state = :sys.get_state(view.pid)
    socket = state.socket

    assert socket.assigns.financial_data_capability.state == :locked
    assert socket.assigns.payload.fleet.agent_totals == %{seconds_running: 41}
    refute Map.has_key?(socket.assigns.payload.fleet, :rate_limits)
    refute inspect(state) =~ sentinel
    refute html =~ sentinel
    refute render(view) =~ sentinel
    refute log =~ sentinel
  end

  test "configured Basic Auth survives the LiveView socket boundary as private financial authority" do
    orchestrator_name = Module.concat(__MODULE__, :AuthenticatedFinancialBoundaryOrchestrator)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "socket-bound-secret")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      dashboard_auth_required: true,
      dashboard_writable: false
    )

    unauthenticated = get(build_conn(), "/")
    assert response(unauthenticated, 401) == "Unauthorized"

    conn =
      build_conn()
      |> Plug.Conn.put_req_header(
        "authorization",
        "Basic " <> Base.encode64("operator:socket-bound-secret")
      )

    assert {:ok, view, _html} = live(conn, "/")
    socket = :sys.get_state(view.pid).socket

    assert socket.assigns.financial_data_capability == %{state: :authorized, version: 1}
    assert %AiurWeb.FinancialDataAccess.Context{} = socket.private.aiur_financial_data_access
    refute inspect(socket.private.aiur_financial_data_access) =~ "operator"
    refute inspect(socket.private.aiur_financial_data_access) =~ "socket-bound-secret"
    assert socket.assigns.writable == false
  end

  test "cached payload follows a same-name DecisionMetrics replacement" do
    orchestrator_name = Module.concat(__MODULE__, :RestartCacheOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RestartCacheDecisionStore)
    metrics_name = Module.concat(__MODULE__, :RestartCacheDecisionMetrics)
    requested_at = ~U[2026-07-12 12:00:00.000Z]

    start_counting_orchestrator(orchestrator_name)

    store =
      start_decision_store(
        decision_store_name,
        fn _decision, _opts -> {:ok, %{status: :accepted, item: %{id: 507}}} end,
        dispatch_delay_ms: 60_000
      )

    assert :ok = Exchange.subscribe("ticket.987.agent.decision.#")
    assert :ok = DecisionPubSub.subscribe()
    decision = request_queue_decision(store, "restart-cache", "987", now: requested_at)
    assert_receive {:event, %{topic: "ticket.987.agent.decision.requested"} = request_event}, 2_000

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "restart-cache-answer",
                 "expected_version" => decision.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "operator"}, now: DateTime.add(requested_at, 2, :second)],
               store
             )

    assert_receive {:event, %{topic: "ticket.987.agent.decision.answered"} = answer_event}, 2_000
    {old_metrics, restart_metrics} = start_restartable_dashboard_metrics(metrics_name, store)
    assert :ok = DecisionMetrics.observe(request_event, old_metrics)
    assert :ok = DecisionMetrics.observe(answer_event, old_metrics)
    drain_metrics_notifications()

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      decision_metrics: metrics_name
    )

    old_payload = PayloadLoader.load(:fresh)
    assert payload_latency(old_payload, decision.decision_id).request_to_decision_ms == 2_000

    GenServer.stop(old_metrics)
    new_metrics = restart_metrics.()
    refute new_metrics == old_metrics

    assert :ok = DecisionMetrics.observe(request_event, new_metrics)
    assert_receive :decision_metrics_changed, 2_000

    cache = AiurWeb.Endpoint.config(:control_center_cache)
    touch_cached_payloads(cache)
    assert map_size(:sys.get_state(cache)) == 1
    assert cached_payloads_fresh?(cache, 400)

    restarted_payload = PayloadLoader.load(:cached)
    restarted_latency = payload_latency(restarted_payload, decision.decision_id)

    assert restarted_latency.requested_at == DateTime.to_iso8601(requested_at)
    assert restarted_latency.request_to_decision_ms == nil

    final_metrics =
      Enum.reduce(1..12, new_metrics, fn _restart, current_metrics ->
        GenServer.stop(current_metrics)
        replacement = restart_metrics.()
        assert :ok = DecisionMetrics.observe(request_event, replacement)

        replacement_payload = PayloadLoader.load(:cached)
        assert payload_latency(replacement_payload, decision.decision_id).request_to_decision_ms == nil
        replacement
      end)

    assert GenServer.whereis(metrics_name) == final_metrics
    assert map_size(:sys.get_state(cache)) == 8
    drain_metrics_notifications()
  end

  test "persists a decision filter in the URL while opening and closing a card" do
    orchestrator_name = Module.concat(__MODULE__, :FilterOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :FilterDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 506}}}
      end)

    decision = request_dashboard_decision(store, "dashboard-filter")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/decisions")

    view
    |> element(~s(button[phx-click="filter-decisions"][phx-value-filter="blocking"]))
    |> render_click()

    assert_patch(view, "/decisions?filter=blocking")

    view
    |> element("#decision-#{decision.decision_id} .decision-card-head")
    |> render_click()

    assert_patch(view, "/decisions/#{decision.decision_id}?filter=blocking")

    view
    |> element("#decision-#{decision.decision_id} .decision-card-head")
    |> render_click()

    assert_patch(view, "/decisions?filter=blocking")

    view
    |> element("#decision-#{decision.decision_id} .decision-card-head")
    |> render_click()

    assert_patch(view, "/decisions/#{decision.decision_id}?filter=blocking")
    render_submit(view, "search-commands", %{"search" => decision.decision_id})
    assert_patch(view, "/decisions?search=#{decision.decision_id}")
  end

  test "ticket query navigation returns the exact Commands ticket instead of identifier prefixes" do
    orchestrator_name = Module.concat(__MODULE__, :ExactTicketQueryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :ExactTicketQueryStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 61}}}
      end)

    exact =
      request_dashboard_decision(store, "exact-ticket-11", "reversible", ticket: %{identifier: "11", title: "Exact ticket", url: nil})

    prefixed =
      request_dashboard_decision(store, "prefixed-ticket-1110", "reversible", ticket: %{identifier: "1110", title: "Prefixed ticket", url: nil})

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/decisions?ticket=11")

    assert has_element?(view, "#decision-#{exact.decision_id}")
    refute has_element?(view, "#decision-#{prefixed.decision_id}")
  end

  test "Open Commands includes every canonical open authority" do
    orchestrator_name = Module.concat(__MODULE__, :MixedAuthorityOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :MixedAuthorityDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_078}}}
      end)

    human = request_dashboard_decision(store, "open-human")

    delegated =
      request_dashboard_decision(store, "open-supervisor", "reversible", decision_authority: :supervisor_allowed)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false
    )

    {:ok, view, _html} = live(build_conn(), "/decisions")

    view
    |> element(~s(button[phx-click="filter-decisions"][phx-value-filter="open"]))
    |> render_click()

    assert_patch(view, "/decisions?filter=open")
    assert has_element?(view, ".decision-list #decision-#{human.decision_id}")
    assert has_element?(view, ".decision-list #decision-#{delegated.decision_id}")
  end

  test "All Commands uses bounded retained pages with shareable search and safe cursor failure" do
    orchestrator_name = Module.concat(__MODULE__, :RetainedPageOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RetainedPageDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_079}}}
      end)

    decisions =
      for index <- 0..26 do
        request_dashboard_decision(store, "retained-page-#{index}", "reversible", now: DateTime.add(~U[2026-07-13 08:00:00Z], index, :second))
      end

    oldest = hd(decisions)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false
    )

    {:ok, view, html} = live(build_conn(), "/decisions")

    assert html =~ "Search retained Commands"
    assert html =~ "Next page"
    refute has_element?(view, "#decision-#{oldest.decision_id}")

    page_two = view |> element(".command-pagination a", "Next page") |> render_click()
    assert page_two =~ oldest.decision_id
    assert has_element?(view, "#decision-#{oldest.decision_id}")
    assert String.starts_with?(assert_patch(view), "/decisions?cursor=")

    search_html = render_submit(view, "search-commands", %{"search" => oldest.decision_id})
    assert_patch(view, "/decisions?search=#{oldest.decision_id}")
    assert search_html =~ oldest.decision_id
    refute search_html =~ "Next page"

    invalid_html = render_patch(view, "/decisions?cursor=not-a-valid-cursor")
    assert invalid_html =~ "Command projection is currently unavailable"
    assert Process.alive?(view.pid)
  end

  test "a direct Decision URL resolves a retained record outside the 50-item overview" do
    orchestrator_name = Module.concat(__MODULE__, :RetainedDetailOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RetainedDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 507}}}
      end)

    oldest = request_dashboard_decision(store, "retained-oldest", "reversible", now: ~U[2026-07-13 08:00:00Z])

    for index <- 1..50 do
      request_dashboard_decision(
        store,
        "retained-newer-#{index}",
        "reversible",
        now: DateTime.add(oldest.created_at, index, :second)
      )
    end

    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == oldest.decision_id))
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name
    )

    {:ok, _view, html} = live(build_conn(), "/decisions/#{oldest.decision_id}")
    assert html =~ oldest.decision_id
    assert html =~ "Should the dashboard ship this change?"
    refute html =~ "Command not found"
  end

  test "a selected retained Decision remains visible when the stale URL filter excludes its lifecycle" do
    orchestrator_name = Module.concat(__MODULE__, :ResolvedSelectionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :ResolvedSelectionStore)
    detail_store_name = Module.concat(__MODULE__, :ResolvedSelectionDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_078}}}
      end)

    overview = request_dashboard_decision(store, "resolved-selected-filter")

    resolved =
      store
      |> replace_dashboard_decision(overview,
        question: "This retained decision is resolved.",
        reversibility: "reversible",
        option_label: "No further action"
      )
      |> Map.put(:decision_status, :resolved)

    start_versioned_detail_store(detail_store_name, overview, resolved)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: detail_store_name,
      control_center_cache: false
    )

    {:ok, _view, html} = live(build_conn(), "/decisions/#{resolved.decision_id}?filter=open")
    assert html =~ "This retained decision is resolved."
    assert html =~ "Resolved"
    refute html =~ "No Commands match this filter."
  end

  test "unavailable or indeterminate detail excludes the matching stale overview row and rejects answers" do
    orchestrator_name = Module.concat(__MODULE__, :StaleAnswerOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :StaleAnswerStore)
    detail_store_name = Module.concat(__MODULE__, :StaleAnswerDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_081}}}
      end)

    overview = request_dashboard_decision(store, "stale-detail-answer")
    start_stale_detail_store(detail_store_name, overview, :unavailable)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: detail_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    for detail_status <- [:unavailable, :indeterminate] do
      assert :ok = GenServer.call(detail_store_name, {:set_detail_status, detail_status})

      {:ok, view, html} = live(build_conn(), "/decisions/#{overview.decision_id}")
      assert html =~ if(detail_status == :unavailable, do: "Command unavailable", else: "Command presence unknown")
      refute html =~ "Should the dashboard ship this change?"
      refute html =~ ~s(phx-submit="answer-decision")

      _html =
        render_submit(view, "answer-decision", %{
          "decision_id" => overview.decision_id,
          "answer" => %{"choice" => "option:ship", "rationale" => "Must not use stale overview data"}
        })

      decision_id = overview.decision_id
      refute_receive {:stale_detail_answer, ^decision_id, _payload, _opts}
    end
  end

  test "unavailable or indeterminate detail excludes the matching stale overview row and rejects revisions" do
    orchestrator_name = Module.concat(__MODULE__, :StaleRevisionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :StaleRevisionStore)
    detail_store_name = Module.concat(__MODULE__, :StaleRevisionDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_082}}}
      end)

    requested = request_dashboard_decision(store, "stale-detail-revision")

    assert {:ok, _accepted} =
             DecisionStore.answer(
               requested.decision_id,
               %{
                 "idempotency_key" => "stale-detail-answer",
                 "expected_version" => requested.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    assert {:ok, overview} = DecisionStore.get(requested.decision_id, store)
    start_stale_detail_store(detail_store_name, overview, :unavailable)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: detail_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    for detail_status <- [:unavailable, :indeterminate] do
      assert :ok = GenServer.call(detail_store_name, {:set_detail_status, detail_status})

      {:ok, view, html} = live(build_conn(), "/decisions/#{overview.decision_id}")
      assert html =~ if(detail_status == :unavailable, do: "Command unavailable", else: "Command presence unknown")
      refute html =~ "Should the dashboard ship this change?"
      refute html =~ ~s(phx-submit="revise-decision")

      _html =
        render_submit(view, "revise-decision", %{
          "decision_id" => overview.decision_id,
          "revision" => %{
            "choice" => "custom",
            "custom_response" => "Must not use stale overview data",
            "reason" => "The exact retained detail is unavailable"
          }
        })

      decision_id = overview.decision_id
      refute_receive {:stale_detail_revision, ^decision_id, _payload, _opts}
    end
  end

  test "a writable answer uses selected retained detail outside the overview window" do
    orchestrator_name = Module.concat(__MODULE__, :OutsideWindowAnswerOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :OutsideWindowAnswerStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_072}}}
      end)

    decision = request_dashboard_decision(store, "outside-window-answer", "reversible", now: ~U[2026-07-13 08:00:00Z])
    add_newer_dashboard_decisions(store, decision, "outside-window-answer-newer")

    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == decision.decision_id))
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/decisions/#{decision.decision_id}")
    assert html =~ "Answer this Command"

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship", "rationale" => "The retained detail remains authoritative"}
      })

    assert html =~ "Answer recorded"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(decision.decision_id, store)
             not is_nil(current.answer)
           end)
  end

  test "a writable revision uses selected retained detail outside the overview window" do
    orchestrator_name = Module.concat(__MODULE__, :OutsideWindowRevisionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :OutsideWindowRevisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_073}}}
      end)

    decision = request_dashboard_decision(store, "outside-window-revision", "reversible", now: ~U[2026-07-13 08:00:00Z])

    assert {:ok, _accepted} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "outside-window-original", "expected_version" => decision.version, "option_id" => "ship"},
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    add_newer_dashboard_decisions(store, decision, "outside-window-revision-newer")
    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == decision.decision_id))
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/decisions/#{decision.decision_id}")
    assert html =~ "Revise Command"

    html =
      render_submit(view, "revise-decision", %{
        "decision_id" => decision.decision_id,
        "revision" => %{
          "choice" => "custom",
          "custom_response" => "Hold for the retained evidence",
          "reason" => "The overview window advanced"
        }
      })

    assert html =~ "Revision recorded"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(decision.decision_id, store)
             current.revision_sequence == 1
           end)
  end

  test "an answer keeps the selected retained detail when a concurrent overview refresh omits it" do
    orchestrator_name = Module.concat(__MODULE__, :StalePayloadAnswerOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :StalePayloadAnswerStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_074}}}
      end)

    decision = request_dashboard_decision(store, "stale-payload-answer", "reversible", now: ~U[2026-07-13 08:00:00Z])
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/decisions/#{decision.decision_id}")
    add_newer_dashboard_decisions(store, decision, "stale-payload-answer-newer")
    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == decision.decision_id))
    assert reload_view(view) =~ "Answer this Command"

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship", "rationale" => "The direct selection remains current"}
      })

    assert html =~ "Answer recorded"
  end

  test "a revision keeps the selected retained detail when a concurrent overview refresh omits it" do
    orchestrator_name = Module.concat(__MODULE__, :StalePayloadRevisionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :StalePayloadRevisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_075}}}
      end)

    decision = request_dashboard_decision(store, "stale-payload-revision", "reversible", now: ~U[2026-07-13 08:00:00Z])

    assert {:ok, _accepted} =
             DecisionStore.answer(
               decision.decision_id,
               %{"idempotency_key" => "stale-payload-original", "expected_version" => decision.version, "option_id" => "ship"},
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/decisions/#{decision.decision_id}")
    add_newer_dashboard_decisions(store, decision, "stale-payload-revision-newer")
    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == decision.decision_id))
    assert reload_view(view) =~ "Revise Command"

    html =
      render_submit(view, "revise-decision", %{
        "decision_id" => decision.decision_id,
        "revision" => %{
          "choice" => "custom",
          "custom_response" => "Retain the safer correction",
          "reason" => "The overview changed while this detail stayed selected"
        }
      })

    assert html =~ "Revision recorded"
  end

  test "an answer uses the rendered retained version when the overview has an older same-ID row" do
    orchestrator_name = Module.concat(__MODULE__, :VersionedAnswerOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :VersionedAnswerStore)
    detail_store_name = Module.concat(__MODULE__, :VersionedAnswerDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_076}}}
      end)

    overview = request_dashboard_decision(store, "versioned-answer")

    detail =
      replace_dashboard_decision(store, overview,
        question: "Destroy the active release?",
        reversibility: "irreversible",
        option_label: "Destroy the active release"
      )

    start_versioned_detail_store(detail_store_name, overview, detail)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: detail_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/decisions/#{detail.decision_id}")
    assert html =~ "Destroy the active release?"
    assert html =~ "Destroy the active release"
    assert html =~ "I understand this Command is irreversible or destructive."
    refute html =~ "Should the dashboard ship this change?"

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => detail.decision_id,
        "answer" => %{
          "choice" => "option:ship",
          "confirmed" => "true",
          "rationale" => "The current retained detail is destructive"
        }
      })

    assert html =~ "Answer recorded"

    assert_receive {:versioned_detail_answer, decision_id, payload, _opts}
    assert decision_id == detail.decision_id
    assert payload["expected_version"] == detail.version
  end

  test "a revision uses the rendered retained version when the overview has an older same-ID row" do
    orchestrator_name = Module.concat(__MODULE__, :VersionedRevisionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :VersionedRevisionStore)
    detail_store_name = Module.concat(__MODULE__, :VersionedRevisionDetailStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_077}}}
      end)

    overview = request_dashboard_decision(store, "versioned-revision")

    assert {:ok, _accepted} =
             DecisionStore.answer(
               overview.decision_id,
               %{
                 "idempotency_key" => "versioned-revision-original",
                 "expected_version" => overview.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    detail =
      replace_dashboard_decision(store, overview,
        question: "Destroy the active release after review?",
        reversibility: "irreversible",
        option_label: "Destroy the reviewed release"
      )

    start_versioned_detail_store(detail_store_name, overview, detail)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: detail_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/decisions/#{detail.decision_id}")
    assert html =~ "Destroy the active release after review?"
    assert html =~ "Destroy the reviewed release"
    assert html =~ "I understand this revised Command is irreversible or destructive."
    refute html =~ "Should the dashboard ship this change?"

    html =
      render_submit(view, "revise-decision", %{
        "decision_id" => detail.decision_id,
        "revision" => %{
          "choice" => "option:ship",
          "confirmed" => "true",
          "reason" => "The retained version changes the operation"
        }
      })

    assert html =~ "Revision recorded"

    assert_receive {:versioned_detail_revision, decision_id, payload, _opts}
    assert decision_id == detail.decision_id
    assert payload["expected_version"] == detail.version
    assert payload["expected_action_id"] == detail.active_action_id
  end

  test "a retained version refresh clears an answer draft and confirmation" do
    orchestrator_name = Module.concat(__MODULE__, :AnswerRefreshOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :AnswerRefreshStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_079}}}
      end)

    initial = request_dashboard_decision(store, "answer-refresh", "irreversible")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      control_center_reload_timer: fn pid, message, _delay -> send(pid, message) end,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/decisions/#{initial.decision_id}")

    draft_html =
      render_change(view, "decision-action-change", %{
        "decision_id" => initial.decision_id,
        "answer" => %{
          "choice" => "option:ship",
          "confirmed" => "true",
          "rationale" => "Draft from the old retained version"
        }
      })

    assert draft_html =~ "Draft from the old retained version"
    assert draft_html =~ ~s(name="answer[confirmed]" value="true" checked)

    refreshed =
      replace_dashboard_decision(store, initial,
        question: "Destroy the refreshed answer target?",
        reversibility: "irreversible",
        option_label: "Destroy the refreshed target"
      )

    assert eventually(fn -> render(view) =~ "Destroy the refreshed answer target?" end, 80)
    refreshed_html = render(view)
    assert refreshed_html =~ "Destroy the refreshed answer target?"
    refute refreshed_html =~ "Draft from the old retained version"
    refute refreshed_html =~ ~s(name="answer[confirmed]" value="true" checked)

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => refreshed.decision_id,
        "answer" => %{
          "choice" => "option:ship",
          "confirmed" => "true",
          "rationale" => "Confirmed after the retained refresh"
        }
      })

    assert html =~ "Answer recorded"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(refreshed.decision_id, store)
             not is_nil(current.answer)
           end)
  end

  test "a retained version refresh clears a revision draft and confirmation" do
    orchestrator_name = Module.concat(__MODULE__, :RevisionRefreshOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RevisionRefreshStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_080}}}
      end)

    overview = request_dashboard_decision(store, "revision-refresh", "irreversible")

    assert {:ok, _accepted} =
             DecisionStore.answer(
               overview.decision_id,
               %{
                 "idempotency_key" => "revision-refresh-original",
                 "expected_version" => overview.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "test"}],
               store
             )

    {:ok, initial} = DecisionStore.get(overview.decision_id, store)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      control_center_reload_timer: fn pid, message, _delay -> send(pid, message) end,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/decisions/#{initial.decision_id}")

    draft_html =
      render_change(view, "decision-revision-change", %{
        "decision_id" => initial.decision_id,
        "revision" => %{
          "choice" => "option:ship",
          "confirmed" => "true",
          "reason" => "Draft from the old active action"
        }
      })

    assert draft_html =~ "Draft from the old active action"
    assert draft_html =~ ~s(name="revision[confirmed]" value="true" checked)

    refreshed =
      store
      |> replace_dashboard_decision(initial,
        question: "Destroy the refreshed revision target?",
        reversibility: "irreversible",
        option_label: "Destroy the refreshed revision target"
      )

    assert eventually(fn -> render(view) =~ "Destroy the refreshed revision target?" end, 80)
    refreshed_html = render(view)
    assert refreshed_html =~ "Destroy the refreshed revision target?"
    refute refreshed_html =~ "Draft from the old active action"
    refute refreshed_html =~ ~s(name="revision[confirmed]" value="true" checked)

    html =
      render_submit(view, "revise-decision", %{
        "decision_id" => refreshed.decision_id,
        "revision" => %{
          "choice" => "option:ship",
          "confirmed" => "true",
          "reason" => "Confirmed after the retained refresh"
        }
      })

    assert html =~ "Revision recorded"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(refreshed.decision_id, store)
             current.revision_sequence == 1
           end)
  end

  test "a direct Decision route resolves once for each LiveView parameter pass" do
    orchestrator_name = Module.concat(__MODULE__, :DirectRouteOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DirectRouteStore)
    counting_store_name = Module.concat(__MODULE__, :DirectRouteCountingStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_071}}}
      end)

    decision = request_dashboard_decision(store, "direct-route")

    start_supervised!({CountingDetailStore, name: counting_store_name, store: decision_store_name})
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: counting_store_name
    )

    {:ok, _view, _html} = live(build_conn(), "/decisions/#{decision.decision_id}")

    assert CountingDetailStore.retained_lookup_count(counting_store_name) == 2
  end

  test "a missing Decision URL stays distinct from a retained-store outage" do
    orchestrator_name = Module.concat(__MODULE__, :MissingRetainedDetailOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :MissingRetainedDetailStore)

    start_decision_store(decision_store_name, fn _decision, _opts -> {:ok, %{status: :accepted, item: %{id: 508}}} end)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name
    )

    {:ok, _view, html} = live(build_conn(), "/decisions/dec-retained-missing")
    assert html =~ "Command not found"
    assert html =~ "No retained Command matches dec-retained-missing."
    refute html =~ "Command unavailable"
  end

  test "malformed filter and agent-log events do not crash the dashboard" do
    orchestrator_name = Module.concat(__MODULE__, :MalformedEventOrchestrator)
    start_counting_orchestrator(orchestrator_name)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 100)

    {:ok, view, _html} = live(build_conn(), "/decisions")

    assert render_hook(view, "filter-decisions", %{}) =~ "Commands inbox"
    assert render_hook(view, "toggle-fleet-filter", %{}) =~ "Commands inbox"
    assert render_hook(view, "show-agent-log", %{}) =~ "Commands inbox"
    assert Process.alive?(view.pid)
  end

  test "writable decision form records once and retries a canonical delivery failure" do
    orchestrator_name = Module.concat(__MODULE__, :ActionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :ActionDecisionStore)
    counter = :counters.new(1, [])

    dispatcher = fn _decision, _opts ->
      :ok = :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)

      if attempt == 1,
        do: {:error, :no_running_agent},
        else: {:ok, %{status: :accepted, item: %{id: 501}}}
    end

    store = start_decision_store(decision_store_name, dispatcher)
    decision = request_dashboard_decision(store, "dashboard-action")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/decisions/#{decision.decision_id}")
    assert html =~ "Answer this Command"
    assert html =~ ~s(phx-submit="answer-decision")

    draft_html =
      render_change(view, "decision-action-change", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "custom", "custom_response" => "Draft answer"}
      })

    assert draft_html =~ "Draft answer"

    params = %{
      "decision_id" => decision.decision_id,
      "answer" => %{"choice" => "option:ship", "rationale" => "Checks are green"}
    }

    _html = render_submit(view, "answer-decision", params)
    html = render(view)
    assert html =~ "Answer recorded"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(decision.decision_id, store)
             current.delivery_status == :failed
           end)

    assert eventually(fn -> render(view) =~ "Delivery · Failed" end, 100)
    html = render(view)
    assert html =~ "Recorded answer"
    assert html =~ "Delivery · Failed"
    assert html =~ ~s(phx-click="retry-decision")

    html = view |> element(~s(button[phx-click="retry-decision"])) |> render_click()
    assert html =~ "delivery retry was scheduled"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(decision.decision_id, store)
             current.delivery_status == :queued
           end)

    assert eventually(fn -> render(view) =~ "Delivery · Queued" end, 100)
    html = render(view)
    assert html =~ "Delivery · Queued"
    refute html =~ ~s(phx-click="retry-decision")

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :answer_recorded}, &1)) == 1
    assert Enum.count(audit, &match?(%DecisionEvent{type: :failed}, &1)) == 1
    assert Enum.count(audit, &match?(%DecisionEvent{type: :dispatch_queued}, &1)) == 1
  end

  test "irreversible answers require confirmation in the server event handler" do
    orchestrator_name = Module.concat(__MODULE__, :ConfirmationOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :ConfirmationDecisionStore)

    dispatcher = fn _decision, _opts ->
      {:ok, %{status: :accepted, item: %{id: 502}}}
    end

    store = start_decision_store(decision_store_name, dispatcher)
    decision = request_dashboard_decision(store, "dashboard-confirmation", "irreversible")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/decisions/#{decision.decision_id}")
    assert html =~ "I understand this Command is irreversible or destructive."

    params = %{
      "decision_id" => decision.decision_id,
      "answer" => %{"choice" => "option:ship"}
    }

    html = render_submit(view, "answer-decision", params)
    assert html =~ "Confirm that you understand this irreversible or destructive action."

    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert is_nil(current.answer)

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    refute Enum.any?(audit, &match?(%DecisionEvent{type: :answer_recorded}, &1))
  end

  test "a socket mounted writable fails closed when the endpoint gate changes" do
    orchestrator_name = Module.concat(__MODULE__, :GateChangeOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :GateChangeDecisionStore)
    test_pid = self()

    dispatcher = fn _decision, _opts ->
      send(test_pid, :unexpected_gate_change_dispatch)
      {:ok, %{status: :accepted, item: %{id: 503}}}
    end

    store = start_decision_store(decision_store_name, dispatcher)
    decision = request_dashboard_decision(store, "dashboard-gate-change")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/decisions/#{decision.decision_id}")
    assert html =~ ~s(phx-submit="answer-decision")

    endpoint_config = Application.fetch_env!(:aiur, AiurWeb.Endpoint)
    disabled_config = Keyword.put(endpoint_config, :dashboard_writable, false)
    Application.put_env(:aiur, AiurWeb.Endpoint, disabled_config)
    :ok = AiurWeb.Endpoint.config_change([{AiurWeb.Endpoint, disabled_config}], [])

    params = %{
      "decision_id" => decision.decision_id,
      "answer" => %{"choice" => "option:ship"}
    }

    html = render_submit(view, "answer-decision", params)
    assert html =~ "Read-only mode · Command mutation controls are hidden."
    refute html =~ ~s(phx-submit="answer-decision")

    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert is_nil(current.answer)
    refute_received :unexpected_gate_change_dispatch
  end

  test "stale answer rejection keeps the draft and explains the canonical refresh" do
    orchestrator_name = Module.concat(__MODULE__, :StaleActionOrchestrator)
    store_name = Module.concat(__MODULE__, :RejectingDecisionStoreInstance)
    decision = dashboard_decision("dec-stale-dashboard")

    start_supervised!({RejectingDecisionStore, name: store_name, decision: decision, report: self()})
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: store_name,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/decisions/#{decision.decision_id}")

    params = %{
      "decision_id" => decision.decision_id,
      "answer" => %{"choice" => "custom", "custom_response" => "Use the safer path", "rationale" => "Lower risk"}
    }

    _html = render_submit(view, "answer-decision", params)
    html = render(view)

    assert html =~ "changed to version 2"
    assert html =~ "Use the safer path"
    assert html =~ ~s(phx-submit="answer-decision")

    assert_receive {:dashboard_answer_attempt, decision_id, payload, opts}
    assert decision_id == decision.decision_id
    assert payload["expected_version"] == 1
    assert payload["custom_response"] == "Use the safer path"
    assert String.starts_with?(payload["idempotency_key"], "ui_")
    assert opts[:actor].kind == :operator
  end

  test "append-only revision preserves the original answer and obeys the writable gate" do
    orchestrator_name = Module.concat(__MODULE__, :RevisionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RevisionDecisionStore)

    dispatcher = fn _decision, _opts ->
      {:ok, %{status: :accepted, item: %{id: System.unique_integer([:positive])}}}
    end

    store = start_decision_store(decision_store_name, dispatcher)
    decision = request_dashboard_decision(store, "dashboard-revision", "irreversible")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/decisions/#{decision.decision_id}")

    _html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship", "confirmed" => "true"}
      })

    assert eventually(fn -> render(view) =~ ~s(phx-submit="revise-decision") end, 100)

    revision_params = %{
      "decision_id" => decision.decision_id,
      "revision" => %{
        "choice" => "custom",
        "custom_response" => "Hold deployment until the incident closes",
        "reason" => "New production evidence"
      }
    }

    assert render_change(view, "decision-revision-change", revision_params) =~
             "Hold deployment until the incident closes"

    html = render_submit(view, "revise-decision", revision_params)
    assert html =~ "Confirm that you understand this revised direction"

    assert {:ok, unchanged} = DecisionStore.get(decision.decision_id, store)
    assert unchanged.revision_sequence == 0

    html =
      render_submit(view, "revise-decision", %{
        revision_params
        | "revision" => Map.put(revision_params["revision"], "confirmed", "true")
      })

    assert html =~ "Revision recorded"
    assert html =~ "A revision records new direction"
    assert html =~ "Original answer · preserved"
    assert html =~ "Hold deployment until the incident closes"
    assert html =~ "New production evidence"
    assert html =~ "Current revised answer"

    assert {:ok, revised} = DecisionStore.get(decision.decision_id, store)
    assert revised.revision_sequence == 1
    assert revised.answer.selected_option_id == "ship"
    assert Decision.active_answer(revised).custom_response == "Hold deployment until the incident closes"
    assert revised.active_action_id == List.last(revised.revisions).action_id

    disable_dashboard_writes()

    html = render_submit(view, "revise-decision", revision_params)
    assert html =~ "Original answer · preserved"
    assert html =~ "Read-only mode · Command mutation controls are hidden."
    refute html =~ ~s(phx-submit="revise-decision")

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :revision_recorded}, &1)) == 1
  end

  test "un-applicable revision exposes and handles the parent follow-up" do
    orchestrator_name = Module.concat(__MODULE__, :RevisionFollowUpOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RevisionFollowUpDecisionStore)

    dispatcher = fn dispatched, _opts ->
      if dispatched.revision_sequence > 0,
        do: {:no_longer_applicable, :missing},
        else: {:ok, %{status: :accepted, item: %{id: 504}}}
    end

    store =
      start_decision_store(decision_store_name, dispatcher,
        revision_follow_up_projector: fn _decision, _action_id -> :ok end,
        revision_follow_up_resolver: fn _decision, _action_id -> :ok end
      )

    decision = request_dashboard_decision(store, "dashboard-revision-follow-up")
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/decisions/#{decision.decision_id}")

    _html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship"}
      })

    _html =
      render_submit(view, "revise-decision", %{
        "decision_id" => decision.decision_id,
        "revision" => %{
          "choice" => "custom",
          "custom_response" => "Stop the inactive rollout",
          "reason" => "The target is no longer active"
        }
      })

    assert eventually(fn -> render(view) =~ "Executor follow-up required" end, 100)

    {:ok, pending} = DecisionStore.get(decision.decision_id, store)

    {action_id, follow_up} =
      Enum.find(pending.revision_follow_ups, fn {_action_id, item} ->
        is_nil(item.handled_at)
      end)

    refute follow_up.question =~ ~r/rolled back|reverted|undone/i

    html =
      render_submit(view, "handle-revision-follow-up", %{
        "decision_id" => decision.decision_id,
        "action_id" => action_id,
        "follow_up" => %{"detail" => "Opened an incident command and notified the operator"}
      })

    assert html =~ "Revision follow-up handled"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(decision.decision_id, store)
             not is_nil(current.revision_follow_ups[action_id].handled_at)
           end)

    assert {:ok, handled} = DecisionStore.get(decision.decision_id, store)

    assert handled.revision_follow_ups[action_id].handled_detail ==
             "Opened an incident command and notified the operator"

    assert handled.revision_follow_ups[action_id].handled_by.kind == :operator
  end

  test "stale revision rejection preserves the corrective draft" do
    orchestrator_name = Module.concat(__MODULE__, :StaleRevisionOrchestrator)
    source_store_name = Module.concat(__MODULE__, :StaleRevisionSourceStore)
    rejecting_store_name = Module.concat(__MODULE__, :RejectingRevisionStoreInstance)

    source_store =
      start_decision_store(source_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 505}}}
      end)

    decision = request_dashboard_decision(source_store, "dashboard-stale-revision")

    assert {:ok, _accepted} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "stale-revision-original",
                 "expected_version" => decision.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "test"}],
               source_store
             )

    assert {:ok, answered} = DecisionStore.get(decision.decision_id, source_store)

    start_supervised!({RejectingRevisionStore, name: rejecting_store_name, decision: answered, report: self()})

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: rejecting_store_name,
      dashboard_writable: true
    )

    {:ok, view, _html} = live(build_conn(), "/decisions/#{decision.decision_id}")

    html =
      render_submit(view, "revise-decision", %{
        "decision_id" => decision.decision_id,
        "revision" => %{
          "choice" => "custom",
          "custom_response" => "Keep the safer correction",
          "reason" => "The canonical action moved"
        }
      })

    assert html =~ "active action changed"
    assert html =~ "Keep the safer correction"
    assert html =~ "The canonical action moved"
    assert html =~ ~s(phx-submit="revise-decision")

    assert_receive {:dashboard_revision_attempt, decision_id, payload, opts}
    assert decision_id == decision.decision_id
    assert payload["expected_version"] == answered.version
    assert payload["expected_action_id"] == answered.active_action_id
    assert payload["expected_revision_sequence"] == 0
    assert String.starts_with?(payload["idempotency_key"], "ui_rev_")
    assert opts[:actor].kind == :operator
  end

  test "human dashboard answer traverses the real queue and target lifecycle" do
    orchestrator_name = Module.concat(__MODULE__, :CapstoneOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :CapstoneDecisionStore)
    metrics_name = Module.concat(__MODULE__, :CapstoneDecisionMetrics)
    recent_merge_store_name = Module.concat(__MODULE__, :CapstoneRecentMergeStore)

    orchestrator = start_queue_orchestrator(orchestrator_name, "987")

    store = start_decision_store(decision_store_name, dispatch_via(orchestrator), dispatch_delay_ms: 0)

    metrics = start_dashboard_metrics(metrics_name, store)
    recent_merges = start_recent_merge_store(recent_merge_store_name)
    decision = request_queue_decision(store, "dashboard-capstone", "987")
    assert :ok = DecisionPubSub.subscribe()

    assert {:ok, merge} =
             RecentMerge.from_github_event(merged_event(),
               live?: true,
               run_id: "capstone-run",
               now: ~U[2026-07-12 18:01:00Z]
             )

    assert {:ok, %{status: :accepted}} = RecentMergeStore.upsert(merge, recent_merges)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      decision_metrics: metrics,
      recent_merge_store: recent_merge_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    path = "/decisions/#{decision.decision_id}"
    {:ok, view, html} = live(build_conn(), path)
    assert html =~ "Answer this Command"
    assert html =~ "Command latency"

    _html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship", "rationale" => "The integrated checks are green"}
      })

    assert_receive {:decision_changed, decision_id, 1}, 2_000
    assert decision_id == decision.decision_id
    assert_receive {:decision_changed, ^decision_id, 1}, 2_000
    assert {:ok, queued} = DecisionStore.get(decision.decision_id, store)
    assert queued.delivery_status == :queued
    assert queued.decision_status == :decided
    assert_receive {:agent_queue_updated, "987", queue_item_id, _delivery}, 2_000

    assert {:ok, %{id: ^queue_item_id} = item} =
             OperatorMessages.claim_next_queue_item(orchestrator, "987")

    assert item.correlation.decision_id == decision.decision_id
    assert item.action_id == queued.answer.action_id
    assert {:ok, :accepted} = DecisionStore.record_delivery(item, store)
    assert reload_view(view) =~ "Delivered"

    lifecycle_payload = %{
      "decision_id" => decision.decision_id,
      "action_id" => item.action_id,
      "expected_version" => decision.version,
      "detail" => "Answer observed and applied"
    }

    lifecycle_opts = [
      ticket_identifier: "987",
      actor: %{kind: :agent, id: "ticket-agent"},
      source: %{agent_id: "codex", session_id: "capstone-session", invocation_id: "capstone-ack"}
    ]

    assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
             DecisionStore.agent_lifecycle(:acknowledged, lifecycle_payload, lifecycle_opts, store)

    assert reload_view(view) =~ "Acknowledged"

    assert {:ok, %{status: :accepted, decision_status: :resolved}} =
             DecisionStore.agent_lifecycle(
               :resolved,
               Map.put(lifecycle_payload, "detail", "Work completed"),
               lifecycle_opts,
               store
             )

    resolved_html = reload_view(view)
    assert resolved_html =~ "Resolved"
    assert resolved_html =~ "Human"
    refute render(view) =~ "Command not found"

    root_html = render_patch(view, "/")
    assert root_html =~ "987"
    assert root_html =~ "Recent repository merges"
    assert root_html =~ "Repository merge"
    assert root_html =~ "Command history"
    assert root_html =~ "dashboard"

    detail_html = render_patch(view, path)
    assert detail_html =~ decision.decision_id
    assert detail_html =~ "Command latency"
    assert detail_html =~ "Request to Command"
    refute detail_html =~ "Command not found"

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)

    assert Enum.map(audit, fn
             %Decision{} -> :requested
             %DecisionEvent{type: type} -> type
           end) == [:requested, :answer_recorded, :dispatch_queued, :delivered, :acknowledged, :resolved]
  end

  test "human dashboard revision traverses the corrective queue and lifecycle projections" do
    orchestrator_name = Module.concat(__MODULE__, :RevisionCapstoneOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :RevisionCapstoneDecisionStore)
    metrics_name = Module.concat(__MODULE__, :RevisionCapstoneDecisionMetrics)

    orchestrator = start_queue_orchestrator(orchestrator_name, "987")

    issue_fetcher = fn ["987"] ->
      {:ok,
       [
         %Issue{
           id: "987",
           identifier: "987",
           state: "in-progress",
           title: "Operator Control Center"
         }
       ]}
    end

    store =
      start_decision_store(
        decision_store_name,
        dispatch_via(orchestrator, issue_fetcher: issue_fetcher),
        dispatch_delay_ms: 0
      )

    metrics = start_dashboard_metrics(metrics_name, store)
    assert :ok = DecisionPubSub.subscribe()
    assert :ok = Exchange.subscribe("ticket.987.agent.decision.revision-recorded")
    decision = request_queue_decision(store, "dashboard-revision-capstone", "987")

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      decision_metrics: metrics,
      control_center_cache: false,
      dashboard_writable: true
    )

    path = "/decisions/#{decision.decision_id}"
    {:ok, view, _html} = live(build_conn(), path)

    _html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{
          "choice" => "option:ship",
          "rationale" => "Initial production evidence supports shipping"
        }
      })

    assert_receive {:agent_queue_updated, "987", original_queue_id, _delivery}, 2_000

    assert {:ok, %{id: ^original_queue_id} = original_item} =
             OperatorMessages.claim_next_queue_item(orchestrator, "987")

    assert {:ok, original_queued} = DecisionStore.get(decision.decision_id, store)
    original_action_id = original_queued.active_action_id
    assert original_item.action_id == original_action_id
    assert original_item.correlation.decision_id == decision.decision_id
    assert {:ok, :accepted} = DecisionStore.record_delivery(original_item, store)

    lifecycle_opts = [
      ticket_identifier: "987",
      actor: %{kind: :agent, id: "ticket-agent"},
      source: %{
        agent_id: "codex",
        session_id: "revision-capstone-session",
        invocation_id: "revision-capstone-lifecycle"
      }
    ]

    original_lifecycle = %{
      "decision_id" => decision.decision_id,
      "action_id" => original_action_id,
      "expected_version" => decision.version,
      "detail" => "Original direction applied"
    }

    assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
             DecisionStore.agent_lifecycle(:acknowledged, original_lifecycle, lifecycle_opts, store)

    assert {:ok, %{status: :accepted, decision_status: :resolved}} =
             DecisionStore.agent_lifecycle(:resolved, original_lifecycle, lifecycle_opts, store)

    assert {:ok, _initial_metrics} = DecisionMetrics.snapshot(decision.decision_id, metrics)
    drain_metrics_notifications()
    assert reload_view(view) =~ "Resolved"

    revision_html =
      render_submit(view, "revise-decision", %{
        "decision_id" => decision.decision_id,
        "revision" => %{
          "choice" => "custom",
          "custom_response" => "Hold deployment until the incident closes",
          "reason" => "New production evidence invalidated the original direction"
        }
      })

    assert revision_html =~ "Revision recorded"
    assert revision_html =~ "Original answer · preserved"
    assert revision_html =~ "Hold deployment until the incident closes"
    assert_receive {:event, revision_metric_event}, 2_000
    normalized_metric_event = DecisionMetricsEvent.normalize(revision_metric_event, DateTime.utc_now())

    assert match?({:ok, _fact}, normalized_metric_event),
           "revision event was not metric-compatible: #{inspect(revision_metric_event)}"

    assert_receive :decision_metrics_changed, 2_000
    assert_receive {:agent_queue_updated, "987", revision_queue_id, _delivery}, 2_000

    assert {:ok, %{id: ^revision_queue_id} = revision_item} =
             OperatorMessages.claim_next_queue_item(orchestrator, "987")

    assert {:ok, revision_queued} = DecisionStore.get(decision.decision_id, store)
    revised_answer = Decision.active_answer(revision_queued)

    assert revision_queued.revision_sequence == 1
    assert revision_queued.revision_result == :dispatched
    assert revision_queued.active_action_id == revised_answer.action_id
    assert revision_queued.active_action_id != original_action_id
    assert is_nil(revision_queued.acknowledgement)
    assert is_nil(revision_queued.resolution)
    assert revision_item.action_id == revised_answer.action_id
    assert revision_item.correlation.decision_id == decision.decision_id
    assert revision_item.correlation.decision_version == decision.version
    assert revision_item.correlation.prior_action_id == original_action_id
    assert revision_item.correlation.revision_sequence == 1
    assert revision_item.correlation.actor.kind == :operator
    assert revision_item.body.text =~ "corrective, append-only direction"
    assert {:ok, :accepted} = DecisionStore.record_delivery(revision_item, store)

    revised_lifecycle = %{
      "decision_id" => decision.decision_id,
      "action_id" => revised_answer.action_id,
      "expected_version" => revised_answer.decision_version,
      "detail" => "Corrective direction applied"
    }

    assert {:ok, %{status: :accepted, decision_status: :acknowledged}} =
             DecisionStore.agent_lifecycle(:acknowledged, revised_lifecycle, lifecycle_opts, store)

    assert {:ok, %{status: :accepted, decision_status: :resolved}} =
             DecisionStore.agent_lifecycle(:resolved, revised_lifecycle, lifecycle_opts, store)

    assert {:ok, metrics_snapshot} = DecisionMetrics.snapshot(decision.decision_id, metrics)
    assert metrics_snapshot.revised
    assert metrics_snapshot.actor == "human"

    history = DecisionHistory.list(server: store, limit: 100)

    revised_history =
      Enum.find(history, fn entry ->
        entry.action_id == revised_answer.action_id and entry.revision_result == :dispatched
      end)

    assert revised_history.change == :revised
    assert revised_history.prior_action_id == original_action_id
    assert revised_history.revision_sequence == 1
    assert revised_history.choice == "Hold deployment until the incident closes"
    assert revised_history.actor.type == :human_operator

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)

    assert Enum.map(audit, fn
             %Decision{} -> :requested
             %DecisionEvent{type: type} -> type
           end) == [
             :requested,
             :answer_recorded,
             :dispatch_queued,
             :delivered,
             :acknowledged,
             :resolved,
             :revision_recorded,
             :revision_dispatched,
             :delivered,
             :acknowledged,
             :resolved
           ]

    detail_html = reload_view(view)
    assert detail_html =~ "Resolved"
    assert detail_html =~ "Revision 1"
    assert detail_html =~ "Revised"
    assert detail_html =~ "Human"

    root_html = render_patch(view, "/")
    assert root_html =~ "Command history"
    assert root_html =~ "Hold deployment until the incident closes"
  end

  test "connected cached dashboard converges from store-first revision to concrete metrics" do
    orchestrator_name = Module.concat(__MODULE__, :MetricsConvergenceOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :MetricsConvergenceDecisionStore)
    metrics_name = Module.concat(__MODULE__, :MetricsConvergenceDecisionMetrics)
    requested_at = ~U[2026-07-12 12:00:00.000Z]

    start_counting_orchestrator(orchestrator_name, report: self())
    orchestrator = GenServer.whereis(orchestrator_name)

    store =
      start_decision_store(
        decision_store_name,
        fn _decision, _opts -> {:ok, %{status: :accepted, item: %{id: 508}}} end,
        dispatch_delay_ms: 60_000
      )

    metrics = start_dashboard_metrics(metrics_name, store, subscribe?: false)
    assert :ok = Exchange.subscribe("ticket.987.agent.decision.#")
    decision = request_queue_decision(store, "metrics-convergence", "987", now: requested_at)
    assert_receive {:event, %{topic: "ticket.987.agent.decision.requested"} = request_event}, 2_000

    assert {:ok, %{status: :accepted, action: original}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "metrics-convergence-answer",
                 "expected_version" => decision.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "operator"}, now: DateTime.add(requested_at, 2, :second)],
               store
             )

    assert_receive {:event, %{topic: "ticket.987.agent.decision.answered"} = answer_event}, 2_000

    assert {:ok, %{status: :accepted}} =
             DecisionStore.revise(
               decision.decision_id,
               %{
                 "idempotency_key" => "metrics-convergence-revision",
                 "expected_version" => decision.version,
                 "expected_action_id" => original.action_id,
                 "expected_revision_sequence" => 0,
                 "custom_response" => "Hold the cached rollout",
                 "rationale" => "New production evidence"
               },
               [actor: %{kind: :operator, id: "operator"}, now: DateTime.add(requested_at, 3, :second)],
               store
             )

    assert_receive {:event, %{topic: "ticket.987.agent.decision.revision-recorded"} = revision_event}, 2_000
    assert DecisionMetrics.snapshots(metrics) == %{}

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      decision_metrics: metrics_name,
      dashboard_writable: true
    )

    assert is_pid(AiurWeb.Endpoint.config(:control_center_cache))

    path = "/decisions/#{decision.decision_id}"
    {:ok, view, initial_html} = live(build_conn(), path)

    assert initial_html =~ "Hold the cached rollout"
    assert initial_html =~ "Revision 1"
    assert initial_html =~ "No latency sample has been retained for this Command yet."
    assert_receive {:dashboard_payload_loaded, ^orchestrator, _count}, 2_000
    drain_dashboard_payload_notifications(orchestrator)
    assert :ok = DecisionPubSub.subscribe()

    for event <- [request_event, answer_event, revision_event] do
      assert :ok = DecisionMetrics.observe(event, metrics)
      assert_receive :decision_metrics_changed, 2_000
    end

    assert_receive {:dashboard_payload_loaded, ^orchestrator, _count}, 2_000
    converged_html = render(view)
    latency_text = converged_html |> Floki.parse_document!() |> Floki.find(".decision-latency") |> Floki.text()

    refute converged_html =~ "No latency sample has been retained for this Command yet."
    assert latency_text =~ "2.0 s"
    assert latency_text =~ "3.0 s"
    assert latency_text =~ "0 reminders"
    assert latency_text =~ "0 attentions"
    assert latency_text =~ "Human"
    assert latency_text =~ "Revised"
  end

  test "connected mount catches one metrics seed hint released between handshake mounts" do
    orchestrator_name = Module.concat(__MODULE__, :HandshakeOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :HandshakeDecisionStore)
    metrics_name = Module.concat(__MODULE__, :HandshakeDecisionMetrics)
    requested_at = ~U[2026-07-12 12:00:00.000Z]

    start_counting_orchestrator(orchestrator_name)

    store =
      start_decision_store(
        decision_store_name,
        fn _decision, _opts -> {:ok, %{status: :accepted, item: %{id: 509}}} end,
        dispatch_delay_ms: 60_000
      )

    decision = request_queue_decision(store, "handshake-metrics", "987", now: requested_at)

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "handshake-metrics-answer",
                 "expected_version" => decision.version,
                 "option_id" => "ship"
               },
               [actor: %{kind: :operator, id: "operator"}, now: DateTime.add(requested_at, 2, :second)],
               store
             )

    test_process = self()

    seed_fun = fn decision_store, limit ->
      send(test_process, {:metrics_seed_waiting, self()})

      receive do
        :release_metrics_seed -> DecisionMetricsCanonical.snapshot(decision_store, limit)
      end
    end

    metrics =
      start_dashboard_metrics(metrics_name, store,
        subscribe?: false,
        seed?: true,
        seed_fun: seed_fun
      )

    assert_receive {:metrics_seed_waiting, seed_process}, 2_000

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      decision_metrics: metrics_name
    )

    path = "/decisions/#{decision.decision_id}"
    conn = get(build_conn(), path)
    disconnected_html = html_response(conn, 200)

    assert disconnected_html =~ "Recorded answer"
    assert disconnected_html =~ "No latency sample has been retained for this Command yet."
    assert :ok = DecisionPubSub.subscribe()

    send(seed_process, :release_metrics_seed)
    assert :ok = DecisionMetrics.await_seed(metrics)
    assert_receive :decision_metrics_changed, 2_000
    refute_receive :decision_metrics_changed, 50

    {:ok, _view, connected_html} = live(conn)
    latency_text = connected_html |> Floki.parse_document!() |> Floki.find(".decision-latency") |> Floki.text()

    refute connected_html =~ "No latency sample has been retained for this Command yet."
    assert latency_text =~ "2.0 s"
    assert latency_text =~ "Human"
  end

  test "supervisor API mutations converge on LiveView without weakening human-required authority" do
    orchestrator_name = Module.concat(__MODULE__, :SupervisorCapstoneOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :SupervisorCapstoneDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: System.unique_integer([:positive])}}}
      end)

    start_counting_orchestrator(orchestrator_name)

    human = request_api_decision(store, "human-required", :human_required)

    delegated =
      request_api_decision(store, "supervisor-allowed", :supervisor_allowed,
        provenance: %{
          agent_family: "codex",
          backend: "codex-app-server",
          requested_model: "gpt-requested",
          resolved_model: "gpt-resolved",
          session_id: "history-thread",
          attempt_id: "history-attempt",
          source: "agent_runner"
        }
      )

    api_opts = supervisor_api_opts(store)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, human_html} = live(build_conn(), "/decisions/#{human.decision_id}")
    assert human_html =~ "Human required"

    assert {:error, {:delegation_forbidden, %{reasons: [:human_required]}}} =
             DecisionApi.decide(human.decision_id, supervisor_decision_payload(1), api_opts)

    assert {:ok, current_human} = DecisionStore.get(human.decision_id, store)
    assert current_human.decision_status == :open
    assert is_nil(current_human.answer)

    delegated_path = "/decisions/#{delegated.decision_id}"
    delegated_html = render_patch(view, delegated_path)
    assert delegated_html =~ "Supervisor allowed"

    assert {:ok, %{"status" => "accepted", "decision" => enriched}} =
             DecisionApi.enrich(
               delegated.decision_id,
               %{
                 "expected_version" => 1,
                 "context" => %{"short_summary" => "Supervisor-enriched canonical context"}
               },
               api_opts
             )

    assert enriched["version"] == 2
    assert reload_view(view) =~ "Supervisor-enriched canonical context"

    assert {:ok, decided} =
             DecisionApi.decide(
               delegated.decision_id,
               supervisor_decision_payload(2),
               api_opts
             )

    action_id = decided["action"]["action_id"]
    assert decided["action"]["actor"] == %{"kind" => "supervisor", "id" => "supervising-agent"}
    assert reload_view(view) =~ "Use the canonical path"

    assert {:ok, revised} =
             DecisionApi.revise(
               delegated.decision_id,
               supervisor_revision_payload(action_id, 2),
               api_opts
             )

    assert revised["action"]["answer"]["actor"] == %{
             "kind" => "supervisor",
             "id" => "supervising-agent"
           }

    detail_html = reload_view(view)
    assert detail_html =~ "Use the corrected path"
    assert detail_html =~ "Original answer · preserved"
    assert detail_html =~ "Revision 1"
    refute detail_html =~ "Command not found"

    _root_html = render_patch(view, "/")
    root_html = reload_view(view)
    assert root_html =~ "Command history"
    assert root_html =~ "supervising-agent"
    assert root_html =~ "codex-app-server · gpt-resolved"
    assert root_html =~ "91% confidence"
    assert root_html =~ "88% confidence"
    assert root_html =~ "Supersedes"
    assert root_html =~ action_id

    _filtered_html = render_patch(view, "/decisions?filter=supervisor")
    filtered_list = view |> element(".decision-list") |> render()
    assert filtered_list =~ delegated.question
    refute filtered_list =~ human.question
  end

  test "keeps the mounted dashboard decision history bounded" do
    orchestrator_name = Module.concat(__MODULE__, :BoundedHistoryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :BoundedHistoryDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 507}}}
      end)

    start_counting_orchestrator(orchestrator_name)
    install_decision_history!(store, 51)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/")

    rows = view |> render() |> Floki.parse_document!() |> Floki.find(".history-list .history-item")
    assert length(rows) == 50
  end

  test "round-trips validated Units URL state and exposes a named zero-result reset" do
    identity = units_identity()
    membership = units_membership(identity)
    orchestrator_name = Module.concat(__MODULE__, :UnitsURLOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    :sys.replace_state(orchestrator, &Map.put(&1, :snapshot, units_orchestrator_snapshot(identity)))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end
    )

    {:ok, view, html} = live(build_conn(), "/?v=1&scope=all&conditions=active")

    assert html =~ "Responsive Units interface"
    assert has_element?(view, ~s(button[phx-value-scope="all"][aria-pressed="true"]))
    assert has_element?(view, ~s(button[phx-value-condition="active"][aria-pressed="true"]))

    view
    |> element(~s(button[phx-value-condition="paused"]))
    |> render_click()

    assert_patch(view, "/?v=1&scope=all&conditions=active%2Cpaused")
    assert has_element?(view, ~s(button[phx-value-condition="active"][aria-pressed="true"]))
    assert has_element?(view, ~s(button[phx-value-condition="paused"][aria-pressed="true"]))

    view
    |> element(~s(button[phx-value-scope="none"]))
    |> render_click()

    assert_patch(view, "/?v=1&scope=none&conditions=active%2Cpaused")
    assert has_element?(view, ~s(button[phx-click="reset-units-filters"]), "Reset Units filters")

    view
    |> element(~s(button[phx-click="reset-units-filters"]))
    |> render_click()

    assert_patch(view, "/?v=1")
    assert has_element?(view, ~s(button[phx-value-scope="live"][aria-pressed="true"]))
    assert has_element?(view, "#units-rows .units-row")

    invalid_html = render_patch(view, "/?v=999&scope=none&conditions=finished")
    assert invalid_html =~ "Responsive Units interface"
    assert_patch(view, "/?v=1")
    assert has_element?(view, ~s(button[phx-value-scope="live"][aria-pressed="true"]))
    refute has_element?(view, ~s(button[phx-value-condition="finished"][aria-pressed="true"]))
  end

  test "keeps valid Units selection and stable typed row identity across catalog updates" do
    identity = units_identity()
    {:ok, membership} = Agent.start_link(fn -> units_membership(identity) end)
    {:ok, activity} = Agent.start_link(fn -> units_activity(identity) end)
    orchestrator_name = Module.concat(__MODULE__, :UnitsUpdateOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    :sys.replace_state(orchestrator, &Map.put(&1, :snapshot, units_orchestrator_snapshot(identity)))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> Agent.get(membership, & &1) end,
      units_activity_fun: fn -> Agent.get(activity, & &1) end
    )

    {:ok, view, _html} = live(build_conn(), "/?v=1&scope=all")
    initial_document = view |> render() |> Floki.parse_document!()
    [row_id] = Floki.attribute(initial_document, ".units-row", "id")
    initial_announcement = initial_document |> Floki.find("#units-status") |> Floki.text()

    Agent.update(membership, fn snapshot ->
      member = snapshot.members |> hd() |> Map.merge(%{lifecycle: :terminal, terminal?: true})
      %{snapshot | generation: 2, members: [member]}
    end)

    Agent.update(activity, fn snapshot ->
      entry = snapshot.entries |> hd() |> put_in([:progress, :percent], 75)
      %{snapshot | generation: 2, entries: [entry]}
    end)

    send(view.pid, {:current_run_membership_changed, %{generation: 2}})
    send(view.pid, {:ticket_activity_changed, %{generation: 2}})
    send(view.pid, :reload_payload)
    _state = :sys.get_state(view.pid)

    assert has_element?(view, ~s(button[phx-value-scope="all"][aria-pressed="true"]))
    assert has_element?(view, "##{row_id}")
    updated_html = render(view)
    assert updated_html =~ "Terminal"
    assert has_element?(view, "##{row_id}", "75%")

    updated_announcement = updated_html |> Floki.parse_document!() |> Floki.find("#units-status") |> Floki.text()
    refute updated_announcement == initial_announcement
    assert updated_announcement =~ ~r/Catalog update [a-f0-9]{10}/
  end

  test "opens shared ticket context only after explicit inspection and gates updates by typed identity" do
    identity = units_identity()
    membership = units_membership(identity)
    orchestrator_name = Module.concat(__MODULE__, :UnitsContextOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()
    {:ok, subscription_attempts} = Agent.start_link(fn -> 0 end)

    :sys.replace_state(orchestrator, &Map.put(&1, :snapshot, units_orchestrator_snapshot(identity)))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      ticket_context_reset_subscribe_fun: fn ->
        send(test_pid, :ticket_context_resets_subscribed)
        :ok
      end,
      ticket_detail_subscribe_fun: fn selected ->
        attempt = Agent.get_and_update(subscription_attempts, fn current -> {current + 1, current + 1} end)
        send(test_pid, {:detail_subscribed, selected, attempt})
        if attempt == 1, do: {:error, :temporarily_unavailable}, else: :ok
      end,
      ticket_history_subscribe_fun: fn selected ->
        send(test_pid, {:history_subscribed, selected})
        :ok
      end,
      ticket_detail_unsubscribe_fun: fn selected ->
        send(test_pid, {:detail_unsubscribed, selected})
        :ok
      end,
      ticket_history_unsubscribe_fun: fn selected ->
        send(test_pid, {:history_unsubscribed, selected})
        :ok
      end,
      ticket_detail_request_fun: fn selected ->
        send(test_pid, {:detail_requested, selected})
        {:ok, units_ticket_detail(selected, "Responsive Units interface")}
      end,
      ticket_history_request_fun: fn selected ->
        send(test_pid, {:history_requested, selected})
        {:ok, units_ticket_history(selected)}
      end
    )

    {:ok, view, html} = live(build_conn(), "/")
    assert_receive :ticket_context_resets_subscribed
    refute_receive :ticket_context_resets_subscribed
    assert html =~ "Responsive Units interface"
    refute html =~ "units-ticket-context"
    refute_receive {:detail_requested, _identity}
    refute_receive {:history_requested, _identity}

    html = view |> element(~s(button[phx-click="inspect-unit"])) |> render_click()

    assert_receive {:detail_subscribed, ^identity, 1}
    assert_receive {:history_subscribed, ^identity}
    assert_receive {:detail_requested, ^identity}
    assert_receive {:history_requested, ^identity}
    assert html =~ ~s(id="units-ticket-context")
    assert html =~ "Ticket context"
    assert html =~ "Responsive Units interface"
    assert html =~ "Issue"
    assert html =~ "Chat is unavailable"
    assert html =~ "Commands"
    assert html =~ ~s(href="/decisions?ticket=1110")
    refute html =~ "/private/workspace"

    other = units_identity(provider_id: "NODE-other", identifier: "1111")
    send(view.pid, {:ticket_detail_updated, units_ticket_detail(other, "Wrong ticket")})
    refute render(view) =~ "Wrong ticket"

    send(view.pid, {:ticket_detail_updated, units_ticket_detail(identity, "Updated ticket context")})
    assert render(view) =~ "Updated ticket context"

    view |> element("#units-ticket-context button", "Close") |> render_click()
    refute_receive {:detail_unsubscribed, ^identity}
    assert_receive {:history_unsubscribed, ^identity}
    refute has_element?(view, "#units-ticket-context")

    html = view |> element(~s(button[phx-click="inspect-unit"])) |> render_click()
    assert_receive {:detail_subscribed, ^identity, 2}
    assert_receive {:history_subscribed, ^identity}
    refute_receive :ticket_context_resets_subscribed
    assert_receive {:detail_requested, ^identity}
    assert_receive {:history_requested, ^identity}
    assert html =~ ~s(id="units-ticket-context")
  end

  test "opens a read-only conversation drawer from the explicit action and closes it truthfully" do
    identity = units_identity()
    membership = units_membership(identity)
    handle = conversation_handle_value("a")
    orchestrator_name = Module.concat(__MODULE__, :ConversationOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    :sys.replace_state(
      orchestrator,
      &Map.put(&1, :snapshot, units_conversation_snapshot(identity, handle))
    )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      live_conversation_resolve_fun: fn resolved ->
        send(test_pid, {:conversation_resolved, resolved})
        {:ok, conversation_snapshot(handle)}
      end,
      live_conversation_subscribe_fun: fn resolved ->
        send(test_pid, {:conversation_subscribed, resolved})
        :ok
      end,
      live_conversation_unsubscribe_fun: fn resolved ->
        send(test_pid, {:conversation_unsubscribed, resolved})
        :ok
      end
    )

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Read conversation"
    refute html =~ "units-conversation-drawer"

    html =
      view
      |> element(~s(button[phx-click="read-conversation"]))
      |> render_click()

    assert_receive {:conversation_resolved, ^handle}
    assert_receive {:conversation_subscribed, ^handle}
    assert html =~ ~s(id="units-conversation-drawer")
    assert html =~ "not participating"
    assert html =~ "its-everdred/aiur #1110"
    assert html =~ "Reviewing the drawer"
    refute html =~ handle
    refute html =~ "units-ticket-context"

    view |> element(~s(#units-conversation-drawer button), "Close") |> render_click()
    assert_receive {:conversation_unsubscribed, ^handle}
    refute has_element?(view, "#units-conversation-drawer")
  end

  test "ordinary row inspection opens ticket context, not the conversation drawer" do
    identity = units_identity()
    membership = units_membership(identity)
    handle = conversation_handle_value("b")
    orchestrator_name = Module.concat(__MODULE__, :ConversationRegressionOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    :sys.replace_state(
      orchestrator,
      &Map.put(&1, :snapshot, units_conversation_snapshot(identity, handle))
    )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      ticket_detail_request_fun: fn selected ->
        {:ok, units_ticket_detail(selected, "Responsive Units interface")}
      end,
      ticket_history_request_fun: fn selected -> {:ok, units_ticket_history(selected)} end,
      live_conversation_resolve_fun: fn _handle ->
        send(test_pid, :unexpected_resolve)
        {:ok, conversation_snapshot(handle)}
      end
    )

    {:ok, view, _html} = live(build_conn(), "/")

    html = view |> element(~s(button[phx-click="inspect-unit"])) |> render_click()

    assert html =~ ~s(id="units-ticket-context")
    refute html =~ ~s(id="units-conversation-drawer")
    refute_receive :unexpected_resolve
  end

  test "the conversation drawer replaces only the pinned generation and ignores other handles" do
    identity = units_identity()
    membership = units_membership(identity)
    handle = conversation_handle_value("c")
    other_handle = conversation_handle_value("d")
    orchestrator_name = Module.concat(__MODULE__, :ConversationUpdateOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    :sys.replace_state(
      orchestrator,
      &Map.put(&1, :snapshot, units_conversation_snapshot(identity, handle))
    )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      live_conversation_resolve_fun: fn _handle -> {:ok, conversation_snapshot(handle)} end,
      live_conversation_subscribe_fun: fn _handle -> :ok end
    )

    {:ok, view, _html} = live(build_conn(), "/")
    view |> element(~s(button[phx-click="read-conversation"])) |> render_click()

    send(
      view.pid,
      {:live_conversation_changed, conversation_snapshot(handle, message_body: "Fresh pinned update")}
    )

    assert render(view) =~ "Fresh pinned update"

    send(
      view.pid,
      {:live_conversation_changed, conversation_snapshot(other_handle, message_body: "Replacement worker")}
    )

    html = render(view)
    assert html =~ "Fresh pinned update"
    refute html =~ "Replacement worker"
  end

  test "a projection restart freezes the open conversation drawer as superseded" do
    identity = units_identity()
    membership = units_membership(identity)
    handle = conversation_handle_value("e")
    orchestrator_name = Module.concat(__MODULE__, :ConversationRestartOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    :sys.replace_state(
      orchestrator,
      &Map.put(&1, :snapshot, units_conversation_snapshot(identity, handle))
    )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      live_conversation_resolve_fun: fn _handle -> {:ok, conversation_snapshot(handle)} end,
      live_conversation_subscribe_fun: fn _handle -> :ok end
    )

    {:ok, view, _html} = live(build_conn(), "/")
    view |> element(~s(button[phx-click="read-conversation"])) |> render_click()

    send(view.pid, {:live_conversation_restarted, "epoch-2", ~U[2026-07-17 13:00:00Z]})

    assert render(view) =~ "Superseded"
  end

  test "Agent log writable actions carry the selected typed Unit identity" do
    identity = units_identity()
    membership = units_membership(identity)
    orchestrator_name = Module.concat(__MODULE__, :TypedAgentLogOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    :sys.replace_state(orchestrator, &Map.put(&1, :snapshot, units_orchestrator_snapshot(identity)))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      agent_chat_send_fun: fn selected, text ->
        send(test_pid, {:typed_agent_message, selected, text})
        {:ok, 7}
      end,
      agent_chat_pause_fun: fn selected ->
        send(test_pid, {:typed_agent_pause, selected})
        {:ok, 8}
      end
    )

    {:ok, view, _html} = live(build_conn(), "/")
    token = UnitsPresenter.row_token(%{identity: identity})

    html =
      view
      |> element(~s(button[phx-click="show-agent-log"][phx-value-unit="#{token}"]))
      |> render_click()

    assert html =~ ~s(phx-submit="send-operator-message")

    render_submit(view, "send-operator-message", %{"message" => "typed hello"})
    assert_receive {:typed_agent_message, ^identity, "typed hello"}

    render_hook(view, "pause-agent", %{})
    assert_receive {:typed_agent_pause, ^identity}
  end

  test "ticket context replaces identity subscriptions and keeps common resets singular" do
    alpha = units_identity()
    beta = units_identity(repository: "other", provider_id: "NODE-other", database_id: 1111, identifier: "1111")
    membership = units_membership(alpha)
    membership = %{membership | members: membership.members ++ units_membership(beta).members}
    orchestrator_name = Module.concat(__MODULE__, :TicketContextSubscriptionOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    alpha_row = units_orchestrator_snapshot(alpha).running |> hd()
    beta_row = units_orchestrator_snapshot(beta).running |> hd() |> Map.put(:issue_id, "issue-1111")
    :sys.replace_state(orchestrator, &Map.put(&1, :snapshot, %{units_orchestrator_snapshot(alpha) | running: [alpha_row, beta_row]}))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(alpha) end,
      ticket_context_reset_subscribe_fun: fn ->
        send(test_pid, :context_resets_once)
        :ok
      end,
      ticket_detail_subscribe_fun: &context_subscription(test_pid, :detail_subscribed, &1),
      ticket_history_subscribe_fun: &context_subscription(test_pid, :history_subscribed, &1),
      ticket_detail_unsubscribe_fun: &context_subscription(test_pid, :detail_unsubscribed, &1),
      ticket_history_unsubscribe_fun: &context_subscription(test_pid, :history_unsubscribed, &1),
      ticket_detail_request_fun: fn selected -> {:ok, units_ticket_detail(selected, "Ticket #{selected.identifier}")} end,
      ticket_history_request_fun: fn selected -> {:ok, units_ticket_history(selected)} end
    )

    {:ok, view, _html} = live(build_conn(), "/")
    assert_receive :context_resets_once

    alpha_token = UnitsPresenter.row_token(%{identity: alpha})
    beta_token = UnitsPresenter.row_token(%{identity: beta})

    render_hook(view, "inspect-unit", %{"unit" => alpha_token})
    assert_receive {:detail_subscribed, ^alpha}
    assert_receive {:history_subscribed, ^alpha}

    render_hook(view, "inspect-unit", %{"unit" => beta_token})
    assert_receive {:detail_unsubscribed, ^alpha}
    assert_receive {:history_unsubscribed, ^alpha}
    assert_receive {:detail_subscribed, ^beta}
    assert_receive {:history_subscribed, ^beta}

    render_hook(view, "close-ticket-context", %{})
    assert_receive {:detail_unsubscribed, ^beta}
    assert_receive {:history_unsubscribed, ^beta}

    render_hook(view, "inspect-unit", %{"unit" => alpha_token})
    assert_receive {:detail_subscribed, ^alpha}
    assert_receive {:history_subscribed, ^alpha}
    refute_receive :context_resets_once
  end

  test "Agent log disables and rejects writes for colliding display identifiers" do
    alpha = units_identity()
    beta = units_identity(repository: "other", provider_id: "NODE-other-1110")
    membership = units_membership(alpha)
    membership = %{membership | members: membership.members ++ units_membership(beta).members}
    orchestrator_name = Module.concat(__MODULE__, :CollidingAgentLogOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    alpha_row = units_orchestrator_snapshot(alpha).running |> hd()
    beta_row = units_orchestrator_snapshot(beta).running |> hd() |> Map.put(:issue_id, "issue-other-1110")

    snapshot = %{units_orchestrator_snapshot(alpha) | running: [alpha_row, beta_row]}
    :sys.replace_state(orchestrator, &Map.put(&1, :snapshot, snapshot))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(alpha) end,
      agent_chat_send_fun: fn selected, text ->
        send(test_pid, {:unexpected_agent_message, selected, text})
        {:ok, 9}
      end,
      agent_chat_pause_fun: fn selected ->
        send(test_pid, {:unexpected_agent_pause, selected})
        {:ok, 10}
      end
    )

    {:ok, view, _html} = live(build_conn(), "/")
    token = UnitsPresenter.row_token(%{identity: alpha})

    html =
      view
      |> element(~s(button[phx-click="show-agent-log"][phx-value-unit="#{token}"]))
      |> render_click()

    assert html =~ "not a unique writable target"
    refute html =~ ~s(phx-submit="send-operator-message")
    refute html =~ ~s(phx-click="pause-agent")

    render_submit(view, "send-operator-message", %{"message" => "must not route"})
    render_hook(view, "pause-agent", %{})
    refute_receive {:unexpected_agent_message, _identity, _text}
    refute_receive {:unexpected_agent_pause, _identity}
  end

  test "membership provider failure renders unavailable counts instead of healthy zeros" do
    orchestrator_name = Module.concat(__MODULE__, :UnavailableUnitsOrchestrator)
    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> raise "membership unavailable" end,
      units_activity_fun: fn -> exit(:activity_unavailable) end
    )

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Units unavailable"
    assert html =~ "Observed and selected-scope counts unavailable"
    assert html =~ "Count unavailable"
    assert html =~ "Counts are unavailable"
    refute html =~ "0 observed"
    refute html =~ "0 in selected scope"
  end

  test "Commands count returns to unknown across count-store teardown and recovery" do
    identifier = System.unique_integer([:positive]) |> Integer.to_string()

    identity =
      units_identity(
        identifier: identifier,
        provider_id: "NODE-#{identifier}"
      )

    membership = units_membership(identity)
    orchestrator_name = Module.concat(__MODULE__, :CommandsOutageOrchestrator)
    available_store = Module.concat(__MODULE__, :RecoveredCommandsStore)
    dispatcher = fn _decision, _opts -> {:ok, %{status: :accepted, item: %{id: 77}}} end

    :ok = SubscriptionStore.stop(identifier)
    on_exit(fn -> SubscriptionStore.stop(identifier) end)

    start_decision_store(available_store, dispatcher)
    start_queue_orchestrator(orchestrator_name, identifier, identity)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      decision_store: available_store,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end
    )

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ ~r/Open Commands<\/dt><dd>Unknown<\/dd>/
    refute html =~ ~r/Open Commands<\/dt><dd>None open<\/dd>/

    :ok = SubscriptionStore.attach(identifier)
    assert reload_view(view) =~ ~r/Open Commands<\/dt><dd>None open<\/dd>/

    :ok = SubscriptionStore.stop(identifier)
    html = reload_view(view)
    assert html =~ ~r/Open Commands<\/dt><dd>Unknown<\/dd>/
    refute html =~ ~r/Open Commands<\/dt><dd>None open<\/dd>/

    :ok = SubscriptionStore.attach(identifier)
    assert reload_view(view) =~ ~r/Open Commands<\/dt><dd>None open<\/dd>/

    :ok = SubscriptionStore.stop(identifier)
    html = reload_view(view)
    assert html =~ ~r/Open Commands<\/dt><dd>Unknown<\/dd>/
    refute html =~ ~r/Open Commands<\/dt><dd>None open<\/dd>/
  end

  describe "runtime capacity control" do
    alias Aiur.Orchestrator.Slots

    test "renders authoritative capacity facts from the Slots contract" do
      name = Module.concat(__MODULE__, :CapacityFactsOrchestrator)
      start_capacity_orchestrator(name, 3)

      {_view, html} = mount_capacity_dashboard(name)

      assert html =~ "Agent capacity"
      assert html =~ ~s(<span class="capacity-current num" aria-hidden="true">3</span>)
      assert html =~ ~s(<dd class="num">0</dd>)
      assert html =~ "Session override"
      assert html =~ "Steady"
      # Focus target for status announcements is stable across updates.
      assert html =~ ~s(id="capacity-title" tabindex="-1")
    end

    test "increment raises the maximum through Slots and reconciles from the returned status" do
      name = Module.concat(__MODULE__, :CapacityIncrementOrchestrator)
      start_capacity_orchestrator(name, 3)

      {view, _html} = mount_capacity_dashboard(name)
      html = view |> element("#capacity-increment") |> render_click()

      assert html =~ "Maximum agent capacity is now 4."
      # The applied value is the authoritative Slots value, not a browser guess.
      assert Slots.max_concurrent_agents(name).max == 4
    end

    test "decrement lowers the maximum and disables further decrement at the minimum of one" do
      name = Module.concat(__MODULE__, :CapacityDecrementOrchestrator)
      start_capacity_orchestrator(name, 2)

      {view, _html} = mount_capacity_dashboard(name)
      html = view |> element("#capacity-decrement") |> render_click()

      assert html =~ "Maximum agent capacity is now 1."
      assert Slots.max_concurrent_agents(name).max == 1
      assert html =~ ~r/id="capacity-decrement".*?disabled/s
    end

    test "set applies a validated absolute value from Slots" do
      name = Module.concat(__MODULE__, :CapacitySetOrchestrator)
      start_capacity_orchestrator(name, 3)

      {view, _html} = mount_capacity_dashboard(name)
      html = render_submit(view, "capacity-set", %{"max" => "7"})

      assert html =~ "Maximum agent capacity is now 7."
      assert Slots.max_concurrent_agents(name).max == 7
    end

    test "set to the current maximum reports a no-op rather than a fresh apply" do
      name = Module.concat(__MODULE__, :CapacityNoopOrchestrator)
      start_capacity_orchestrator(name, 4)

      {view, _html} = mount_capacity_dashboard(name)
      html = render_submit(view, "capacity-set", %{"max" => "4"})

      assert html =~ "Maximum agent capacity is unchanged at 4."
    end

    test "rejects non-positive or non-numeric input without calling Slots" do
      name = Module.concat(__MODULE__, :CapacityInvalidOrchestrator)
      start_capacity_orchestrator(name, 3)

      {view, _html} = mount_capacity_dashboard(name)

      for value <- ["0", "-2", "abc", "3.5", ""] do
        html = render_submit(view, "capacity-set", %{"max" => value})
        assert html =~ "Enter a whole number of 1 or more."
        assert Slots.max_concurrent_agents(name).max == 3
      end
    end

    test "reconciles from the returned authoritative value when a concurrent change wins" do
      name = Module.concat(__MODULE__, :CapacityConcurrentOrchestrator)
      start_capacity_orchestrator(name, 3)

      {view, _html} =
        mount_capacity_dashboard(name, capacity_set_fun: fn _next -> {:ok, %{max: 9}} end)

      html = render_submit(view, "capacity-set", %{"max" => "4"})

      assert html =~ "Maximum agent capacity is now 9."
      refute html =~ "now 4."
    end

    test "surfaces the authoritative draining state after lowering capacity" do
      name = Module.concat(__MODULE__, :CapacityDrainingOrchestrator)
      start_capacity_orchestrator(name, 5)

      {view, _html} =
        mount_capacity_dashboard(name,
          capacity_set_fun: fn _next -> {:ok, %{max: 2, draining?: true}} end
        )

      html = render_submit(view, "capacity-set", %{"max" => "2"})

      assert html =~ "Maximum agent capacity is now 2."
      assert html =~ "Extra agents keep running and drain as they finish."
    end

    test "reports a timeout as stale without claiming the requested value applied" do
      name = Module.concat(__MODULE__, :CapacityTimeoutOrchestrator)
      start_capacity_orchestrator(name, 3)

      {view, _html} =
        mount_capacity_dashboard(name, capacity_adjust_fun: fn _delta -> {:error, :timeout} end)

      html = view |> element("#capacity-increment") |> render_click()

      assert html =~ "The capacity service did not respond in time."
      refute html =~ "Maximum agent capacity is now"
    end

    test "reports an unavailable capacity service" do
      name = Module.concat(__MODULE__, :CapacityUnavailableOrchestrator)
      start_capacity_orchestrator(name, 3)

      {view, _html} =
        mount_capacity_dashboard(name, capacity_set_fun: fn _next -> {:error, :unavailable} end)

      html = render_submit(view, "capacity-set", %{"max" => "5"})

      assert html =~ "Capacity control is unavailable right now."
      refute html =~ "Maximum agent capacity is now"
    end

    test "read-only dashboard exposes no usable mutation control" do
      name = Module.concat(__MODULE__, :CapacityReadOnlyOrchestrator)
      start_capacity_orchestrator(name, 3)

      {_view, html} = mount_capacity_dashboard(name, dashboard_writable: false)

      refute html =~ ~s(phx-click="capacity-increment")
      refute html =~ ~s(id="capacity-max-input")
      assert html =~ "Read-only dashboard. Agent capacity is displayed but cannot be changed here."
    end

    test "re-checks writable mode on every activation and rejects a revoked write" do
      name = Module.concat(__MODULE__, :CapacityRevokedOrchestrator)
      start_capacity_orchestrator(name, 3)

      {view, html} = mount_capacity_dashboard(name)
      assert html =~ ~s(phx-click="capacity-increment")

      config = Application.fetch_env!(:aiur, AiurWeb.Endpoint)
      revoked = Keyword.put(config, :dashboard_writable, false)
      Application.put_env(:aiur, AiurWeb.Endpoint, revoked)
      :ok = AiurWeb.Endpoint.config_change([{AiurWeb.Endpoint, revoked}], [])

      html = view |> element("#capacity-increment") |> render_click()

      refute html =~ ~s(phx-click="capacity-increment")
      assert Slots.max_concurrent_agents(name).max == 3
    end

    test "guards double activation with a pending-disable hook" do
      name = Module.concat(__MODULE__, :CapacityPendingOrchestrator)
      start_capacity_orchestrator(name, 3)

      {_view, html} = mount_capacity_dashboard(name)

      assert html =~ ~s(phx-disable-with="Applying…")
    end

    test "preserves the typed absolute value across a re-render" do
      name = Module.concat(__MODULE__, :CapacityFocusOrchestrator)
      start_capacity_orchestrator(name, 3)

      {view, _html} = mount_capacity_dashboard(name)
      html = render_change(view, "capacity-input-change", %{"max" => "42"})

      assert html =~ ~s(value="42")
    end
  end

  defp start_capacity_orchestrator(name, max) do
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    # A serialized control call both forces init to complete before the mount
    # snapshot and establishes a known authoritative maximum via the real Slots
    # contract (as a session override).
    {:ok, %{max: ^max}} = Orchestrator.Slots.set_max_concurrent_agents(name, max)

    name
  end

  defp mount_capacity_dashboard(orchestrator_name, overrides \\ []) do
    start_test_endpoint(
      Keyword.merge(
        [
          orchestrator: orchestrator_name,
          snapshot_timeout_ms: 5_000,
          control_center_cache: false,
          dashboard_writable: true
        ],
        overrides
      )
    )

    {:ok, view, html} = live(build_conn(), "/")
    {view, html}
  end

  defp units_identity(overrides \\ []) do
    struct!(
      TrackerIdentity,
      Keyword.merge(
        [
          status: :joinable,
          kind: :github,
          owner: "its-everdred",
          repository: "aiur",
          provider_id: "NODE-1110",
          database_id: 1110,
          identifier: "1110",
          reason: nil
        ],
        overrides
      )
    )
  end

  defp context_subscription(test_pid, event, identity) do
    send(test_pid, {event, identity})
    :ok
  end

  defp units_membership(identity) do
    observed_at = ~U[2026-07-17 12:00:00Z]

    %{
      run_id: "run-units",
      generation: 1,
      health: :healthy,
      health_message: nil,
      freshness: %{status: :fresh, observed_at: observed_at},
      members: [
        %{
          identity: identity,
          lifecycle: :active,
          terminal?: false,
          first_observed_at: observed_at,
          last_observed_at: observed_at
        }
      ],
      truncated?: false
    }
  end

  defp units_activity(identity) do
    %{
      generation: 1,
      health: :healthy,
      freshness: %{status: :fresh},
      entries: [
        %{
          identity: identity,
          progress: %{status: :known, percent: 50, source: :checkin, freshness: :fresh},
          latest_evidence: %{status: :known, source: %{kind: :branch, name: "feature pushed"}}
        }
      ]
    }
  end

  defp units_orchestrator_snapshot(identity) do
    %{
      running: [
        %{
          issue_id: "issue-1110",
          identifier: "1110",
          tracker_identity: identity,
          state: "in-progress",
          title: "Responsive Units interface",
          url: "https://github.com/its-everdred/aiur/issues/1110",
          labels: ["complexity:3", "build-lane:L2"],
          backend: :codex,
          agent_family: :codex,
          requested_model: "gpt-5.6-terra",
          resolved_model: nil,
          effort: :high,
          complexity: 3,
          build_lane: "L2",
          session_id: "session-1110",
          started_at: ~U[2026-07-17 11:00:00Z],
          last_codex_timestamp: ~U[2026-07-17 11:59:00Z],
          last_codex_event: :progress,
          last_codex_message: "Building responsive Units",
          runtime_seconds: 3_600,
          work_state: :working,
          tracker_paused: false,
          waiting_reason: :active,
          open_decision_count: 0,
          open_decision_count_health: :available,
          control: %{},
          ci_result: nil
        }
      ],
      retrying: [],
      idle: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 3_600},
      rate_limits: nil
    }
  end

  defp conversation_handle_value(seed) when is_binary(seed) do
    "conversation:" <> String.duplicate(seed, 43)
  end

  defp units_conversation_snapshot(identity, handle) do
    snapshot = units_orchestrator_snapshot(identity)

    running =
      snapshot.running
      |> hd()
      |> Map.put(:live_conversation, %{
        generation_handle: handle,
        state: :live,
        health: :healthy,
        freshness: :current,
        observed_at: ~U[2026-07-17 12:00:00Z],
        reason: nil
      })

    %{snapshot | running: [running]}
  end

  defp conversation_snapshot(handle, overrides \\ []) do
    body = Keyword.get(overrides, :message_body, "Reviewing the drawer")
    state = Keyword.get(overrides, :state, :live)

    %{
      version: 1,
      projection_epoch: "epoch-1",
      revision: 1,
      source_revision: 1,
      generation_handle: handle,
      source: %{run_id: "run-units", session_id: "opaque-session", worker_generation: 4},
      state: state,
      health: :healthy,
      freshness: :current,
      messages: [
        %{
          id: "m1",
          role: "agent",
          title: "Assistant",
          body: body,
          occurred_at: ~U[2026-07-17 12:00:00Z],
          observed_at: ~U[2026-07-17 12:00:00Z]
        }
      ],
      observed_at: ~U[2026-07-17 12:00:00Z],
      diagnostic_counts: %{},
      truncated?: false,
      evicted_count: 0
    }
  end

  defp units_ticket_detail(identity, title) do
    observed_at = ~U[2026-07-17 12:00:00Z]

    %Aiur.BuildOrder.TicketDetail.State{
      identity: identity,
      generation: 1,
      health: :healthy,
      detail: %Aiur.BuildOrder.TicketDetail.Snapshot{
        identity: identity,
        title: title,
        description: "Bounded reusable ticket context",
        lifecycle: Lifecycle.from_github("OPEN", nil),
        url: "https://github.com/its-everdred/aiur/issues/#{identity.identifier}",
        created_at: observed_at,
        updated_at: observed_at,
        observed_at: observed_at
      },
      last_success_at: observed_at,
      last_attempt_at: observed_at
    }
  end

  defp units_ticket_history(identity) do
    %Aiur.BuildOrder.TicketHistory.Snapshot{
      identity: identity,
      generation: 1,
      health: :available,
      status_label: "Current activity",
      progress: %{status: :known, percent: 50, source: :checkin, observed_at: ~U[2026-07-17 12:00:00Z]},
      latest_evidence: %{
        status: :known,
        source: %{kind: :branch, name: "feature pushed"},
        observed_at: ~U[2026-07-17 12:00:00Z]
      },
      entries: [],
      truncated?: false,
      observed_at: ~U[2026-07-17 12:00:00Z],
      freshness: :fresh,
      source_health: %{activity: :available, history: :available}
    }
  end

  defp install_decision_history!(store, count) do
    :sys.replace_state(store, fn state ->
      histories = decision_histories(count)

      state
      |> Map.put(:audit_history, histories)
      |> Map.put(:recent_audit, histories |> Map.values() |> List.flatten() |> Enum.reverse())
    end)
  end

  defp decision_histories(count) do
    %{
      "dec-dashboard" =>
        Enum.map(1..count, fn version ->
          %{
            decision_id: "dec-dashboard",
            version: version,
            ticket: %{identifier: "1051", title: "Decision history", url: nil},
            source: %{agent_id: "agent-1", session_id: "session-1", event_id: nil},
            question: "Decision version #{version}?",
            created_at: DateTime.add(~U[2026-07-12 12:00:00Z], version, :second)
          }
        end)
    }
  end

  defp start_run_summary_dashboard do
    test_process = self()

    start_run_summary_dashboard(fn destination, message, delay_ms ->
      send(test_process, {:run_summary_flush_scheduled, destination, message, delay_ms})
      make_ref()
    end)
  end

  defp start_run_summary_dashboard(flush_timer) when is_function(flush_timer, 3) do
    orchestrator_name = Module.concat(__MODULE__, :RunSummaryOrchestrator)

    start_supervised!(
      {CountingOrchestrator,
       name: orchestrator_name,
       snapshot: %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }},
      id: orchestrator_name
    )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      run_summary_flush_timer: flush_timer
    )

    {:ok, view, _html} = live(build_conn(), "/")
    view
  end

  # Deterministically apply one pushed snapshot: process the update (which
  # schedules but defers the coalesced flush), then run the flush and render.
  defp push_summary(view, snapshot) do
    send(view.pid, {:current_run_summary_changed, snapshot})
    :sys.get_state(view.pid)
    send(view.pid, :flush_run_summary)
    render(view)
  end

  defp healthy_summary_snapshot(opts \\ []) do
    live = Keyword.get(opts, :live, 3)
    {num, den} = Keyword.get(opts, :exact, {3, 5})

    %{
      version: 1,
      generation: Keyword.get(opts, :generation, 1),
      run: %{
        id: Keyword.get(opts, :run_id, "run-1"),
        started_at: ~U[2026-07-17 10:00:00Z],
        observed_at: ~U[2026-07-17 10:20:00Z],
        elapsed_wall_ms: 1_200_000,
        elapsed_wall_seconds: 1200,
        valid?: true
      },
      counts: %{live: live, remaining: 2, successful_terminal: 1, non_work_terminal: 0, unknown_state: 0, total: live + 3},
      weights: %{
        eligible: 10,
        successful_terminal: 4,
        remaining: 6,
        excluded: 0,
        excluded_count: 0,
        defaulted: 0,
        defaulted_count: 0,
        known_progress: 10,
        unknown_progress: 0
      },
      progress: %{
        scale: 100,
        weighted_numerator: %{value: 600, scale: 100},
        denominator_weight: 10,
        known_weight: 10,
        unknown_weight: 0,
        lower_bound: %{numerator: num, denominator: den},
        coverage: %{numerator: 1, denominator: 1},
        exact: %{numerator: num, denominator: den}
      },
      eta: %{
        status: :available,
        reason: nil,
        confidence: :evidence_based,
        formula_version: "completed_weight_rate_v1",
        sample_count: 2,
        duration_seconds: %{numerator: 480, denominator: 1},
        throughput_weight_per_second: %{numerator: 1, denominator: 300},
        completed_weight: 4,
        remaining_weight: 6,
        denominator_generation: 1,
        observed_at: ~U[2026-07-17 10:20:00Z]
      },
      health: %{status: :healthy, reasons: []},
      freshness: %{status: :fresh, sources: %{}}
    }
  end

  defp unavailable_same_run_snapshot do
    healthy_summary_snapshot()
    |> Map.put(:generation, 2)
    |> Map.put(:health, %{status: :unavailable, reasons: [:unhealthy_membership]})
    |> Map.put(:freshness, %{status: :unavailable, sources: %{}})
  end

  defp start_outcomes_dashboard do
    test_process = self()

    start_outcomes_dashboard(fn destination, message, delay_ms ->
      send(test_process, {:outcomes_flush_scheduled, destination, message, delay_ms})
      make_ref()
    end)
  end

  defp start_outcomes_dashboard(flush_timer) when is_function(flush_timer, 3) do
    orchestrator_name = Module.concat(__MODULE__, :OutcomesOrchestrator)

    start_supervised!(
      {CountingOrchestrator,
       name: orchestrator_name,
       snapshot: %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }},
      id: orchestrator_name
    )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      current_run_outcomes_flush_timer: flush_timer
    )

    {:ok, view, _html} = live(build_conn(), "/")
    view
  end

  # Deterministically apply one pushed outcome snapshot: process the update
  # (which schedules but defers the coalesced flush), then run the flush.
  defp push_outcomes(view, snapshot) do
    send(view.pid, {:current_run_outcome_snapshot_changed, snapshot})
    :sys.get_state(view.pid)
    send(view.pid, :flush_current_run_outcomes)
    render(view)
  end

  defp healthy_outcomes_snapshot(opts) do
    numbers = Keyword.get(opts, :numbers, [1])
    outcomes = Enum.map(numbers, &outcome_fixture/1)

    %{
      version: 1,
      generation: Keyword.get(opts, :generation, 3),
      state: if(outcomes == [], do: :healthy_empty, else: :healthy),
      run: %{id: Keyword.get(opts, :run_id, "run-1"), started_at: ~U[2026-07-17 10:00:00Z], observed_at: ~U[2026-07-17 12:00:00Z]},
      repository: "its-everdred/aiur",
      membership: %{generation: 4, signature: "sig"},
      outcomes: outcomes,
      counts: %{input: length(outcomes), invalid: 0, deduplicated: length(outcomes), qualified: length(outcomes), returned: length(outcomes)},
      exclusions: %{},
      limit: 100,
      truncated?: false,
      health: %{status: :healthy, reasons: []},
      freshness: %{status: :fresh},
      sources: %{}
    }
  end

  defp unavailable_same_run_outcomes_snapshot(run_id) do
    healthy_outcomes_snapshot(numbers: [], run_id: run_id)
    |> Map.put(:state, :unavailable)
    |> Map.put(:generation, 5)
    |> Map.put(:health, %{status: :unavailable, reasons: [:merge_source_unavailable]})
    |> Map.put(:freshness, %{status: :unavailable})
  end

  defp outcome_fixture(number) do
    identity = %TrackerIdentity{status: :joinable, kind: :github, owner: "its-everdred", repository: "aiur", identifier: "#{number}"}

    %{
      id: "merge-#{number}",
      repository: "its-everdred/aiur",
      number: number,
      title: "Ship #{number}",
      summary: "A short safe summary for #{number}.",
      url: "https://github.com/its-everdred/aiur/pull/#{number}",
      head_ref: "aiur/#{number}-slug",
      head_sha: "abc#{number}",
      merge_commit_sha: "def#{number}",
      merged_at: ~U[2026-07-17 11:00:00Z],
      member: %{identity: identity, identifier: identity.identifier},
      association: %{version: 1, basis: :configured_repository_branch_locator_unique_membership_run_window},
      run: %{id: "run-1", started_at: ~U[2026-07-17 10:00:00Z], observed_at: ~U[2026-07-17 12:00:00Z], membership_generation: 4},
      observation: %{source: :recent_merge_store, backfilled?: false, live_observed?: false, observed_run_id: nil, first_observed_at: nil, last_observed_at: nil}
    }
  end

  defp start_test_endpoint(overrides) do
    previous = Application.get_env(:aiur, AiurWeb.Endpoint)
    cache = start_supervised!({ControlCenterCache, name: nil})

    endpoint_config =
      :aiur
      |> Application.get_env(AiurWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        control_center_cache: cache
      )
      |> Keyword.merge(overrides)

    Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:aiur, AiurWeb.Endpoint)
        config -> Application.put_env(:aiur, AiurWeb.Endpoint, config)
      end
    end)

    start_supervised!({AiurWeb.Endpoint, []})
  end

  defp start_counting_orchestrator(name, opts \\ []) do
    start_supervised!(
      {CountingOrchestrator,
       name: name,
       report: Keyword.get(opts, :report),
       snapshot: %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}
    )
  end

  defp start_queue_orchestrator(name, identifier, tracker_identity \\ nil) do
    parent = self()
    worker_pid = spawn(fn -> worker_probe(parent) end)
    issue_id = "issue-#{identifier}"

    state = %Aiur.Orchestrator.State{
      poll_interval_ms: 5_000,
      max_concurrent_agents: 1,
      effective_concurrent_agents: 1,
      poll_check_in_progress: false,
      running: %{issue_id => running_entry(issue_id, identifier, worker_pid, tracker_identity)},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    start_supervised!({QueueOrchestrator, name: name, state: state})

    on_exit(fn ->
      send(worker_pid, :stop)
    end)

    name
  end

  defp running_entry(issue_id, identifier, worker_pid, tracker_identity) do
    %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{
        id: issue_id,
        identifier: identifier,
        state: "in-progress",
        title: "OCC integration",
        tracker_identity: tracker_identity
      },
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
      session_id: "thread-#{identifier}",
      codex_app_server_pid: nil,
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      last_codex_timestamp: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }
  end

  defp worker_probe(parent) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, message)
        worker_probe(parent)
    end
  end

  defp dispatch_via(orchestrator, dispatcher_opts \\ []) do
    fn decision, opts ->
      opts = Keyword.merge(opts, dispatcher_opts)
      DecisionDispatch.dispatch(decision, Keyword.put(opts, :operator_messages, orchestrator))
    end
  end

  defp start_dashboard_metrics(name, decision_store, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "aiur-dashboard-metrics-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "decision-latency.ndjson")
    on_exit(fn -> File.rm_rf!(dir) end)

    metrics_opts =
      Keyword.merge(
        [name: name, path: path, subscribe?: true, seed?: false, decision_store: decision_store],
        opts
      )

    start_supervised!({DecisionMetrics, metrics_opts})
  end

  defp start_restartable_dashboard_metrics(name, decision_store) do
    dir = Path.join(System.tmp_dir!(), "aiur-dashboard-metrics-restart-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    restart = fn ->
      path = Path.join(dir, "decision-latency-#{System.unique_integer([:positive])}.ndjson")

      {:ok, metrics} =
        DecisionMetrics.start_link(
          name: name,
          path: path,
          subscribe?: false,
          seed?: false,
          decision_store: decision_store
        )

      metrics
    end

    metrics = restart.()

    on_exit(fn ->
      case GenServer.whereis(name) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      File.rm_rf!(dir)
    end)

    {metrics, restart}
  end

  defp start_recent_merge_store(name) do
    dir = Path.join(System.tmp_dir!(), "aiur-dashboard-merges-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!({RecentMergeStore, name: name, state_dir: dir, filesystem_sync_fun: fn -> :ok end})
  end

  defp request_api_decision(store, source_id, authority, opts \\ []) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "source_id" => source_id,
                 "question" => "Choose #{source_id}?",
                 "blocking" => true,
                 "kind" => "architecture",
                 "authority" => Atom.to_string(authority),
                 "reversibility" => "reversible"
               },
               Keyword.merge(
                 [
                   ticket: %{identifier: "AIUR-984", title: "Supervisor decision API", url: nil},
                   source: %{agent_id: "agent-984", session_id: "session-984", event_id: "event-#{source_id}"}
                 ],
                 opts
               ),
               store
             )

    decision
  end

  defp request_queue_decision(store, source_id, identifier, opts \\ []) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{
                 "source_id" => source_id,
                 "question" => "Should the dashboard ship this change?",
                 "blocking" => true,
                 "urgency" => "critical",
                 "reversibility" => "reversible",
                 "options" => [%{"id" => "ship", "label" => "Ship it"}]
               },
               Keyword.merge(
                 [
                   ticket: %{identifier: identifier, title: "Operator Control Center", url: nil},
                   source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-#{source_id}"}
                 ],
                 opts
               ),
               store
             )

    decision
  end

  defp supervisor_api_opts(store) do
    [
      store: store,
      policy: %{allowed_kinds: ["architecture"], allow_non_reversible: false},
      actor: %{kind: :supervisor, id: "supervising-agent"}
    ]
  end

  defp supervisor_decision_payload(expected_version) do
    %{
      "idempotency_key" => "dashboard-supervisor-decision",
      "expected_version" => expected_version,
      "custom_response" => "Use the canonical path",
      "rationale" => "It preserves one append-only lifecycle.",
      "confidence" => 91,
      "alternatives_considered" => ["Wait for more evidence"],
      "reversibility_belief" => "reversible"
    }
  end

  defp supervisor_revision_payload(action_id, expected_version) do
    %{
      "expected_version" => expected_version,
      "expected_action_id" => action_id,
      "expected_revision_sequence" => 0,
      "idempotency_key" => "dashboard-supervisor-revision",
      "custom_response" => "Use the corrected path",
      "rationale" => "New production evidence",
      "confidence" => 88,
      "alternatives_considered" => ["Keep the original direction"],
      "reversibility_belief" => "reversible"
    }
  end

  defp start_decision_store(name, dispatcher, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "aiur-dashboard-decisions-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :decision_state_dir)
    Application.put_env(:aiur, :decision_state_dir, dir)

    on_exit(fn ->
      restore_application_env(:decision_state_dir, previous)
      File.rm_rf!(dir)
    end)

    defaults = [
      name: name,
      dispatcher: dispatcher,
      dispatch_delay_ms: 0,
      retry_delays_ms: [],
      reconcile_delay_ms: 5_000,
      filesystem_sync_fun: fn -> :ok end
    ]

    start_supervised!({DecisionStore, Keyword.merge(defaults, opts)})
  end

  defp request_dashboard_decision(store, source_id, reversibility \\ "reversible", opts \\ []) do
    {decision_authority, opts} = Keyword.pop(opts, :decision_authority)

    request =
      %{
        "source_id" => source_id,
        "question" => "Should the dashboard ship this change?",
        "blocking" => true,
        "urgency" => "critical",
        "reversibility" => reversibility,
        "options" => [
          %{
            "id" => "ship",
            "label" => "Ship it",
            "description" => "Proceed with the reviewed change"
          }
        ],
        "recommendation" => %{"option_id" => "ship", "reason" => "Checks are green"}
      }
      |> then(fn request ->
        if is_atom(decision_authority),
          do: Map.put(request, "authority", decision_authority),
          else: request
      end)

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               request,
               Keyword.merge(
                 [
                   ticket: %{
                     identifier: "AIUR-987",
                     title: "Operator Control Center",
                     url: "https://example.test/issues/987"
                   },
                   source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-#{source_id}"}
                 ],
                 opts
               ),
               store
             )

    decision
  end

  defp add_newer_dashboard_decisions(store, decision, source_prefix) do
    for index <- 1..50 do
      request_dashboard_decision(
        store,
        "#{source_prefix}-#{index}",
        "reversible",
        now: DateTime.add(decision.created_at, index, :second)
      )
    end
  end

  defp replace_dashboard_decision(store, decision, attrs) do
    assert {:ok, %{decision: replacement}} =
             DecisionStore.request(
               %{
                 "source_id" => decision.source_id,
                 "version" => decision.version + 1,
                 "question" => Keyword.fetch!(attrs, :question),
                 "blocking" => true,
                 "urgency" => "critical",
                 "reversibility" => Keyword.fetch!(attrs, :reversibility),
                 "options" => [
                   %{
                     "id" => "ship",
                     "label" => Keyword.fetch!(attrs, :option_label),
                     "description" => "The option ID is intentionally reused with a different meaning"
                   }
                 ],
                 "recommendation" => %{"option_id" => "ship", "reason" => "Current retained evidence"}
               },
               [ticket: decision.ticket, source: decision.source],
               store
             )

    replacement
  end

  defp start_versioned_detail_store(name, overview, detail) do
    opts = [name: name, overview: overview, detail: detail, report: self()]
    start_supervised!({VersionedDetailStore, opts})
  end

  defp start_stale_detail_store(name, overview, detail_status) do
    opts = [name: name, overview: overview, detail_status: detail_status, report: self()]
    start_supervised!({StaleDetailStore, opts})
  end

  defp dashboard_decision(decision_id) do
    %Decision{
      decision_id: decision_id,
      source_id: decision_id,
      version: 1,
      ticket: %{identifier: "AIUR-987", title: "Operator Control Center", url: "https://example.test/issues/987"},
      source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-stale"},
      kind: "architecture",
      authority: :human_required,
      urgency: :critical,
      blocking: true,
      reversibility: :reversible,
      question: "Which implementation should ship?",
      context: %{short_summary: "A newer version exists", long_context_markdown: nil},
      options: [],
      recommendation: nil,
      consequence_of_delay: "The agent remains paused.",
      artifacts: [],
      created_at: ~U[2026-07-12 12:00:00Z],
      source_created_at: nil,
      content_hash: "stale-dashboard-hash"
    }
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)

  defp disable_dashboard_writes do
    endpoint_config = Application.fetch_env!(:aiur, AiurWeb.Endpoint)
    disabled_config = Keyword.put(endpoint_config, :dashboard_writable, false)
    Application.put_env(:aiur, AiurWeb.Endpoint, disabled_config)
    :ok = AiurWeb.Endpoint.config_change([{AiurWeb.Endpoint, disabled_config}], [])
  end

  defp assert_bounded_reload_burst(views, messages, cache, orchestrator, expire? \\ true) do
    baseline_count = CountingOrchestrator.snapshot_count(orchestrator)
    expected_pids = views |> Enum.map(& &1.pid) |> MapSet.new()

    for view <- views, message <- messages do
      send(view.pid, message)
    end

    Enum.each(views, fn view -> :sys.get_state(view.pid) end)

    scheduled_pids =
      Enum.map(views, fn _view ->
        assert_receive {:payload_reload_scheduled, pid, :reload_payload, delay_ms}, 0
        assert delay_ms in 50..450
        pid
      end)

    assert MapSet.new(scheduled_pids) == expected_pids
    assert length(Enum.uniq(scheduled_pids)) == length(views)
    refute_receive {:payload_reload_scheduled, _pid, :reload_payload, _delay_ms}, 0

    if expire?, do: expire_cached_payloads(cache)
    Enum.each(views, &reload_view/1)

    assert CountingOrchestrator.snapshot_count(orchestrator) == baseline_count + 1
  end

  defp expire_cached_payloads(cache) do
    :sys.replace_state(cache, fn entries ->
      Map.new(entries, fn {key, entry} ->
        {key, %{entry | loaded_at_ms: entry.loaded_at_ms - 60_000}}
      end)
    end)
  end

  defp eventually(fun, attempts \\ 30)

  defp eventually(fun, attempts) when is_function(fun, 0) and attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp reload_view(view) do
    send(view.pid, :reload_payload)
    :sys.get_state(view.pid)
    render(view)
  end

  defp drain_metrics_notifications do
    receive do
      :decision_metrics_changed -> drain_metrics_notifications()
    after
      0 -> :ok
    end
  end

  defp drain_dashboard_payload_notifications(orchestrator) do
    receive do
      {:dashboard_payload_loaded, ^orchestrator, _count} ->
        drain_dashboard_payload_notifications(orchestrator)
    after
      0 -> :ok
    end
  end

  defp payload_latency(payload, decision_id) do
    payload.decisions
    |> Enum.find(&(&1.decision_id == decision_id))
    |> get_in([:latency, :snapshot])
  end

  defp touch_cached_payloads(cache) do
    loaded_at_ms = System.monotonic_time(:millisecond)

    :sys.replace_state(cache, fn entries ->
      Map.new(entries, fn {key, entry} -> {key, %{entry | loaded_at_ms: loaded_at_ms}} end)
    end)
  end

  defp cached_payloads_fresh?(cache, max_age_ms) do
    now_ms = System.monotonic_time(:millisecond)

    cache
    |> :sys.get_state()
    |> Map.values()
    |> Enum.all?(&(now_ms - &1.loaded_at_ms < max_age_ms))
  end

  defp history_entry(id, actor_type, actor_label, question) do
    %{
      decision_id: id,
      ticket: %{identifier: "983", title: "OCC-6", url: "https://github.com/owner/repo/issues/983"},
      question: question,
      source_version: 1,
      changed_at: "2026-07-12T18:00:00Z",
      change: :requested,
      actor: %{type: actor_type, id: actor_label, label: actor_label},
      choice: nil,
      rationale: nil,
      dispatch_result: nil,
      acknowledgement_result: nil,
      revision_of: nil,
      superseded_by: nil,
      revised?: false
    }
  end

  defp merged_event do
    %{
      "id" => "dashboard-merge",
      "type" => "PullRequestEvent",
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 42,
          "title" => "<img src=x onerror=alert(1)>",
          "body" => "Repository merge",
          "html_url" => "https://github.com/owner/repo/pull/42",
          "merged" => true,
          "merged_at" => "2026-07-12T18:00:00Z",
          "head" => %{"ref" => "release/2026-07", "sha" => "head-42"},
          "merged_by" => %{"login" => "merger"}
        }
      }
    }
  end
end
