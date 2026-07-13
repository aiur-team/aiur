defmodule AiurWeb.DashboardLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.{Decision, DecisionApi, DecisionDispatch, DecisionEvent, DecisionMetrics, DecisionPubSub, DecisionStore, Issue}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.RecentMerge
  alias Aiur.RecentMergeStore
  alias AiurWeb.{ControlCenterCache, ControlCenterPresenter, DashboardLive, ObservabilityPubSub, Presenter}
  alias AiurWeb.OperatorControlCenter.FleetFilters

  @endpoint AiurWeb.Endpoint

  defmodule CountingOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    def snapshot_count(server), do: GenServer.call(server, :snapshot_count)

    @impl true
    def init(opts) do
      {:ok, %{snapshot: Keyword.fetch!(opts, :snapshot), snapshot_count: 0}}
    end

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply, state.snapshot, %{state | snapshot_count: state.snapshot_count + 1}}
    end

    def handle_call(:snapshot_count, _from, state) do
      {:reply, state.snapshot_count, state}
    end
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
    def handle_call(:list, _from, state), do: {:reply, [state.decision], state}
    def handle_call(:all_history, _from, state), do: {:reply, %{state.decision.decision_id => [state.decision]}, state}

    def handle_call(:all_audit_history, _from, state) do
      {:reply, %{state.decision.decision_id => [state.decision]}, state}
    end

    def handle_call({:recent_audit_history, _limit}, _from, state) do
      {:reply, %{records: [state.decision], contexts: %{}, revisions: %{}}, state}
    end

    def handle_call({:answer, decision_id, payload, opts}, _from, state) do
      send(state.report, {:dashboard_answer_attempt, decision_id, payload, opts})
      {:reply, {:error, {:conflict, {:stale_version, 1, 2}}}, state}
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
    def handle_call(:list, _from, state), do: {:reply, [state.decision], state}
    def handle_call(:all_history, _from, state), do: {:reply, %{state.decision.decision_id => [state.decision]}, state}

    def handle_call(:all_audit_history, _from, state) do
      {:reply, %{state.decision.decision_id => [state.decision]}, state}
    end

    def handle_call({:recent_audit_history, _limit}, _from, state) do
      {:reply, %{records: [state.decision], contexts: %{}, revisions: %{}}, state}
    end

    def handle_call({:revise, decision_id, payload, opts}, _from, state) do
      send(state.report, {:dashboard_revision_attempt, decision_id, payload, opts})
      {:reply, {:error, {:conflict, {:stale_action, "new-active-action"}}}, state}
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
      selected_decision: selected_decision
    }

    assigns
    |> DashboardLive.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  test "renders explicit waiting reasons, staleness, CI/PR, and the idle bucket" do
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

    assert html =~ "MT-900"
    assert html =~ "Waiting for ci"
    assert html =~ "PR #77 Pending"
    assert html =~ "Review not started"
    assert html =~ "MT-901"
    assert html =~ "Waiting for review"
    assert html =~ "Review awaiting"
    assert html =~ "Fleet state"
    assert html =~ "MT-902"
    assert html =~ "Backing off"
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
    assert inbox_html =~ "Decision inbox"
    refute inbox_html =~ ~s(id="recent-title")
    assert detail_html =~ "Recorded"
    assert detail_html =~ "Dispatch pending"
    assert detail_html =~ "The agent remains paused."
    assert detail_html =~ "&lt;script&gt;alert(&#39;no&#39;)&lt;/script&gt;"
    refute detail_html =~ "<script>alert('no')</script>"
    assert detail_html =~ "Read-only mode · mutation controls are hidden."
  end

  test "renders durable decision history, honest merge provenance, and the analytics link during a snapshot outage" do
    history = [
      history_entry("dec-human", :human_operator, "Human operator", "<script>alert('decision')</script>"),
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
    assert html =~ "Decision history"
    assert html =~ "Human operator"
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

  test "coalesces broadcasts and shares the capped reload across open dashboards" do
    orchestrator_name = Module.concat(__MODULE__, :CountingOrchestratorInstance)

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

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 100)

    {:ok, view, _html} = live(build_conn(), "/")
    initial_count = CountingOrchestrator.snapshot_count(orchestrator_name)
    {:ok, second_view, _html} = live(build_conn(), "/")
    assert CountingOrchestrator.snapshot_count(orchestrator_name) == initial_count

    for version <- 1..25 do
      ObservabilityPubSub.broadcast_update()
      DecisionPubSub.broadcast_changed("decision-#{version}", version)
    end

    assert eventually(fn -> CountingOrchestrator.snapshot_count(orchestrator_name) == initial_count + 1 end, 100)
    Process.sleep(100)
    _html = render(view)
    _html = render(second_view)
    assert CountingOrchestrator.snapshot_count(orchestrator_name) == initial_count + 1

    DecisionPubSub.broadcast_changed("decision-only", 26)
    assert eventually(fn -> CountingOrchestrator.snapshot_count(orchestrator_name) == initial_count + 2 end, 100)

    DecisionPubSub.broadcast_metrics_changed()
    assert eventually(fn -> CountingOrchestrator.snapshot_count(orchestrator_name) == initial_count + 3 end, 100)
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
  end

  test "malformed filter and agent-log events do not crash the dashboard" do
    orchestrator_name = Module.concat(__MODULE__, :MalformedEventOrchestrator)
    start_counting_orchestrator(orchestrator_name)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 100)

    {:ok, view, _html} = live(build_conn(), "/decisions")

    assert render_hook(view, "filter-decisions", %{}) =~ "Decision inbox"
    assert render_hook(view, "toggle-fleet-filter", %{}) =~ "Decision inbox"
    assert render_hook(view, "show-agent-log", %{}) =~ "Decision inbox"
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
    assert html =~ "Answer this decision"
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
    assert html =~ "I understand this decision is irreversible or destructive."

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
    assert html =~ "Read-only mode · mutation controls are hidden."
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
    assert html =~ "Read-only mode · mutation controls are hidden."
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

    assert eventually(fn -> render(view) =~ "Operator follow-up required" end, 100)

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
    assert html =~ "Answer this decision"
    assert html =~ "Decision latency"

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
    refute render(view) =~ "Decision not found"

    root_html = render_patch(view, "/")
    assert root_html =~ "987"
    assert root_html =~ "Recent repository merges"
    assert root_html =~ "Repository merge"
    assert root_html =~ "Decision history"
    assert root_html =~ "dashboard"

    detail_html = render_patch(view, path)
    assert detail_html =~ decision.decision_id
    assert detail_html =~ "Decision latency"
    assert detail_html =~ "Request to decision"
    refute detail_html =~ "Decision not found"

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)

    assert Enum.map(audit, fn
             %Decision{} -> :requested
             %DecisionEvent{type: type} -> type
           end) == [:requested, :answer_recorded, :dispatch_queued, :delivered, :acknowledged, :resolved]
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
    delegated = request_api_decision(store, "supervisor-allowed", :supervisor_allowed)
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
    refute detail_html =~ "Decision not found"

    _root_html = render_patch(view, "/")
    root_html = reload_view(view)
    assert root_html =~ "Decision history"
    assert root_html =~ "supervising-agent"

    filtered_html = render_patch(view, "/decisions?filter=supervisor")
    assert filtered_html =~ delegated.question
    refute filtered_html =~ human.question
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

  defp start_counting_orchestrator(name) do
    start_supervised!(
      {CountingOrchestrator,
       name: name,
       snapshot: %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}
    )
  end

  defp start_queue_orchestrator(name, identifier) do
    parent = self()
    worker_pid = spawn(fn -> worker_probe(parent) end)
    issue_id = "issue-#{identifier}"

    state = %Aiur.Orchestrator.State{
      poll_interval_ms: 5_000,
      max_concurrent_agents: 1,
      effective_concurrent_agents: 1,
      poll_check_in_progress: false,
      running: %{issue_id => running_entry(issue_id, identifier, worker_pid)},
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    start_supervised!({QueueOrchestrator, name: name, state: state})

    on_exit(fn ->
      send(worker_pid, :stop)
    end)

    name
  end

  defp running_entry(issue_id, identifier, worker_pid) do
    %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "in-progress", title: "OCC integration"},
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

  defp dispatch_via(orchestrator) do
    fn decision, opts ->
      DecisionDispatch.dispatch(decision, Keyword.put(opts, :operator_messages, orchestrator))
    end
  end

  defp start_dashboard_metrics(name, decision_store) do
    dir = Path.join(System.tmp_dir!(), "aiur-dashboard-metrics-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "decision-latency.ndjson")
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!({DecisionMetrics, name: name, path: path, subscribe?: true, seed?: false, decision_store: decision_store})
  end

  defp start_recent_merge_store(name) do
    dir = Path.join(System.tmp_dir!(), "aiur-dashboard-merges-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!({RecentMergeStore, name: name, state_dir: dir, filesystem_sync_fun: fn -> :ok end})
  end

  defp request_api_decision(store, source_id, authority) do
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
               [
                 ticket: %{identifier: "AIUR-984", title: "Supervisor decision API", url: nil},
                 source: %{agent_id: "agent-984", session_id: "session-984", event_id: "event-#{source_id}"}
               ],
               store
             )

    decision
  end

  defp request_queue_decision(store, source_id, identifier) do
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
               [
                 ticket: %{identifier: identifier, title: "Operator Control Center", url: nil},
                 source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-#{source_id}"}
               ],
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

  defp request_dashboard_decision(store, source_id, reversibility \\ "reversible") do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
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
               },
               [
                 ticket: %{
                   identifier: "AIUR-987",
                   title: "Operator Control Center",
                   url: "https://example.test/issues/987"
                 },
                 source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-#{source_id}"}
               ],
               store
             )

    decision
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
