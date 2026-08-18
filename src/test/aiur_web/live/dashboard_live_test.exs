defmodule AiurWeb.DashboardLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.{
    CommandsCLI,
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
  alias Aiur.Events.Exchange

  alias Aiur.OpenTicketSource.Snapshot, as: OpenTicketSnapshot
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{OperatorMessages, SnapshotStore, StatusReport}
  alias Aiur.RecentMerge
  alias Aiur.RecentMergeStore
  alias AiurWeb.{ControlCenterCache, ControlCenterPresenter, DashboardLive, ObservabilityPubSub, Presenter}
  alias AiurWeb.OperatorControlCenter.{AgentRoutingPreview, FleetFilters, Overview, PayloadLoader, UnitsPresenter}

  @endpoint AiurWeb.Endpoint

  defmodule CountingOrchestrator do
    use GenServer

    alias Aiur.Orchestrator.SnapshotStore

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    def snapshot_count(server), do: GenServer.call(server, :snapshot_count)

    @impl true
    def init(opts) do
      snapshot = Keyword.fetch!(opts, :snapshot)

      if Keyword.get(opts, :publish?, true) do
        :ok = SnapshotStore.publish(Keyword.fetch!(opts, :name), snapshot)
      end

      {:ok, %{snapshot: snapshot, snapshot_count: 0, report: Keyword.get(opts, :report)}}
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

    def handle_call(:request_refresh, _from, state) do
      if is_pid(state.report), do: send(state.report, {:dashboard_refresh_requested, self()})
      {:reply, %{coalesced: false}, state}
    end
  end

  defmodule GlobalPauseFailureOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts), do: {:ok, %{report: Keyword.fetch!(opts, :report)}}

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply,
       %{
         running: [],
         retrying: [],
         idle: [],
         agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         capacity: nil,
         globally_paused: false,
         global_pause: %{globally_paused: false, paused_at: nil, source: nil},
         rate_limits: nil,
         polling: %{checking?: false, next_poll_in_ms: nil, poll_interval_ms: nil}
       }, state}
    end

    def handle_call({:set_global_pause, on?, source}, _from, state) do
      send(state.report, {:global_pause_attempt, on?, source})
      {:reply, {:error, {:global_pause_persistence_failed, :disk_full}}, state}
    end
  end

  defmodule ProviderMeterSourceStub do
    @moduledoc false

    def load(context) do
      report(:load, context)
      config(:snapshots, %{codex: nil, claude: nil})
    end

    def reload(context, message) do
      report(:reload, {context, message})
      config(:reload_snapshots, config(:snapshots, %{codex: nil, claude: nil}))
    end

    def subscribe(context) do
      report(:subscribe, context)
      :ok
    end

    defp report(call, arg) do
      case config(:pid, nil) do
        pid when is_pid(pid) -> send(pid, {:provider_meter_source, call, arg})
        _other -> :ok
      end
    end

    defp config(key, default), do: Map.get(Application.get_env(:aiur, :provider_meter_source_stub, %{}), key, default)
  end

  defmodule DecisionStoreStub do
    @moduledoc """
    Shared retained-store replies for the dashboard stubs.

    The dashboard reads canonical counts and one retained page per route, so a
    stub that answers neither is not a stand-in for the store — it is a store
    that crashes on contact.
    """

    def counts(decision) do
      open = flag(decision.decision_status == :open)
      deferred = flag(decision.decision_status == :deferred)
      blocking = flag(Map.get(decision, :blocking, false))

      %{
        total: 1,
        open: open + deferred,
        blocking: (open + deferred) * blocking,
        deferred: deferred,
        awaiting: open,
        awaiting_blocking: open * blocking
      }
    end

    defp flag(true), do: 1
    defp flag(_false), do: 0

    def empty_query do
      %{
        decisions: [],
        next_key: nil,
        has_next?: false,
        total: 0,
        partial?: false,
        partial_reason: nil,
        counts: %{total: 0, open: 0, blocking: 0, deferred: 0, awaiting: 0, awaiting_blocking: 0},
        health: :writable
      }
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
      {:reply, {:ok, %{counts: DecisionStoreStub.counts(state.detail), health: :writable}}, state}
    end

    def handle_call({:retained_query, _query}, _from, state) do
      {:reply, {:ok, DecisionStoreStub.empty_query()}, state}
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
      counts = %{total: 1, open: 1, blocking: true, deferred: 0, awaiting: 1, awaiting_blocking: true}
      {:reply, {:ok, %{counts: counts, health: :writable}}, state}
    end

    def handle_call({:retained_query, _query}, _from, state) do
      {:reply, {:ok, DecisionStoreStub.empty_query()}, state}
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

    def handle_call({:send_operator_message, issue_identifier, payload}, _from, state) do
      OperatorMessages.send_operator_message_call(state, issue_identifier, payload)
    end

    def handle_call({:claim_next_queue_item, issue_identifier}, _from, state) do
      OperatorMessages.claim_next_queue_item_call(state, issue_identifier)
    end

    def handle_call({:claim_next_checkpoint_queue_item, issue_identifier}, _from, state) do
      OperatorMessages.claim_next_checkpoint_queue_item_call(state, issue_identifier)
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

    def handle_call({:retained_query, _query}, _from, state) do
      {:reply, {:ok, DecisionStoreStub.empty_query()}, state}
    end

    def handle_call({:recent_audit_history, _limit}, _from, state) do
      {:reply, %{records: [state.decision], contexts: %{}, revisions: %{}}, state}
    end

    def handle_call({:answer, decision_id, payload, opts}, _from, state) do
      send(state.report, {:dashboard_answer_attempt, decision_id, payload, opts})
      {:reply, {:error, {:conflict, {:stale_version, 1, 2}}}, state}
    end

    defp retained_counts(decision) do
      {:ok, %{counts: DecisionStoreStub.counts(decision), health: :writable}}
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

    def handle_call({:retained_query, _query}, _from, state) do
      {:reply, {:ok, DecisionStoreStub.empty_query()}, state}
    end

    def handle_call({:recent_audit_history, _limit}, _from, state) do
      {:reply, %{records: [state.decision], contexts: %{}, revisions: %{}}, state}
    end

    def handle_call({:revise, decision_id, payload, opts}, _from, state) do
      send(state.report, {:dashboard_revision_attempt, decision_id, payload, opts})
      {:reply, {:error, {:conflict, {:stale_action, "new-active-action"}}}, state}
    end

    defp retained_counts(decision) do
      {:ok, %{counts: DecisionStoreStub.counts(decision), health: :writable}}
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
      # This helper renders DashboardLive directly, bypassing mount/3, so it has
      # to seed every assign mount/3 seeds — including the server-owned sidebar
      # collapse state the shell reads.
      nav_collapsed: false,
      agent_log_modal: nil,
      drafts: %{},
      chat_errors: %{},
      decision_actions: %{},
      global_pause_error: Keyword.get(opts, :global_pause_error),
      writable: Keyword.get(opts, :writable, false),
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

  defp global_pause_fleet(globally_paused) do
    %{
      generated_at: "2026-07-26T12:00:00Z",
      counts: %{running: 0, retrying: 0, idle: 0},
      running: [],
      retrying: [],
      idle: [],
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      globally_paused: globally_paused
    }
  end

  describe "global pause nav toggle" do
    test "keeps a persisted global pause visible on a stale snapshot before the first restart poll" do
      orchestrator_name = Module.concat(__MODULE__, :RestartedGlobalPauseOrchestrator)

      snapshot = %{
        running: [],
        retrying: [],
        idle: [],
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: nil,
        globally_paused: false
      }

      {:ok, original} = CountingOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
      assert :ok = GenServer.stop(original, :normal)

      {:ok, restarted} =
        CountingOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot, publish?: false)

      on_exit(fn ->
        Aiur.TestSupport.safe_stop(restarted)
      end)

      generation = SnapshotStore.begin_generation(orchestrator_name)

      :ok =
        SnapshotStore.publish_global_pause(orchestrator_name, generation, %{
          globally_paused: true,
          paused_at: ~U[2026-08-02 12:00:00Z],
          source: "dashboard"
        })

      assert {:stale, %{globally_paused: true}, %{reason: :orchestrator_unavailable}} =
               Orchestrator.dashboard_snapshot(orchestrator_name, 100)

      start_test_endpoint(orchestrator: orchestrator_name, dashboard_writable: true)
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "global-pause-toggle is-paused"
      assert html =~ ~s(aria-pressed="true")
      assert html =~ "Resume all agents (globally paused)"
      refute html =~ "global-pause-banner"
    end

    test "renders a pause affordance while the daemon is running and writable" do
      html = render_payload(global_pause_fleet(false), writable: true)

      assert html =~ ~s(id="global-pause-toggle")
      assert html =~ ~s(phx-click="toggle-global-pause")
      assert html =~ ~s(aria-pressed="false")
      assert html =~ "Pause all agents"
      refute html =~ "global-pause-toggle is-paused"
      refute html =~ ~s|aria-label="Resume all agents (globally paused)"|
    end

    test "renders a resume affordance while the daemon is globally paused" do
      html = render_payload(global_pause_fleet(true), writable: true)

      assert html =~ "global-pause-toggle is-paused"
      assert html =~ ~s(aria-pressed="true")
      assert html =~ "Resume all agents (globally paused)"
      # The nav toggle is the only global-pause signal; the standalone banner is gone.
      refute html =~ "global-pause-banner"
      refute html =~ "lift the global pause"
    end

    test "surfaces a persistence error without claiming the toggle changed" do
      html =
        render_payload(global_pause_fleet(false),
          writable: true,
          global_pause_error: "Global pause was not changed because its state could not be persisted."
        )

      assert html =~ ~s(class="readonly-banner global-pause-error")
      assert html =~ "state could not be persisted"
    end

    test "surfaces a persistence failure returned by the real toggle event" do
      orchestrator_name = Module.concat(__MODULE__, :GlobalPauseFailureOrchestrator)

      start_supervised!({GlobalPauseFailureOrchestrator, name: orchestrator_name, report: self()})

      start_test_endpoint(orchestrator: orchestrator_name, dashboard_writable: true)
      {:ok, view, _html} = live(build_conn(), "/")

      html = view |> element("#global-pause-toggle") |> render_click()

      assert_receive {:global_pause_attempt, true, "dashboard"}
      assert html =~ "state could not be persisted"
      assert html =~ "The daemon remains in its previous state"
    end

    test "disables the toggle when the dashboard is read-only" do
      html = render_payload(global_pause_fleet(false), writable: false)

      assert html =~ ~s(id="global-pause-toggle")
      assert html =~ ~s(aria-disabled="true")
      assert html =~ "disabled"
    end

    # The sidebar is `display: none` below 960px, so pause needs a second
    # instance in the mobile nav pill. The theme toggle does not: it lives in
    # the topbar at every resolution, so exactly one ever renders.
    test "places the pause and theme controls for both layouts" do
      html = render_payload(global_pause_fleet(false), writable: true)
      doc = Floki.parse_document!(html)

      mobile_nav = Floki.find(doc, "nav.shell-nav-mobile")
      assert mobile_nav != []

      assert Floki.find(mobile_nav, "#global-pause-toggle-mobile") != [],
             "the mobile nav must carry its own global pause toggle"

      assert Floki.find(doc, ".topbar .toolbar .topbar-controls #global-pause-toggle") != [],
             "the desktop pause toggle sits top right, beside the theme control"

      assert Floki.find(doc, ".topbar .brand-row #global-pause-toggle") == [],
             "the pause toggle moved out of the brand row, which now carries only the brand"

      assert Floki.find(doc, ".topbar .toolbar .topbar-controls #theme-toggle") != [],
             "the theme toggle lives in the topbar, top right"

      assert Floki.find(doc, "aside.shell-sidebar #theme-toggle") == [],
             "the theme toggle moved out of the sidebar brand row"

      assert Floki.find(mobile_nav, "#theme-toggle") == [],
             "the theme toggle is not duplicated into the nav pill"

      # One theme toggle total, and ids stay unique so LiveView can patch each
      # instance independently.
      assert length(Floki.find(doc, "[phx-hook=\"ThemeToggle\"]")) == 1

      for id <- ~w(global-pause-toggle global-pause-toggle-mobile theme-toggle) do
        assert length(Floki.find(doc, "##{id}")) == 1, "duplicate DOM id: #{id}"
      end
    end

    # The clock pill was the topbar's only occupant and forced itself onto its
    # own line on narrow viewports.
    test "the topbar carries no clock" do
      doc =
        global_pause_fleet(false)
        |> render_payload(writable: true)
        |> Floki.parse_document!()

      assert Floki.find(doc, ".topbar time") == []
    end

    test "the mobile pause toggle mirrors paused state and read-only gating" do
      paused = render_payload(global_pause_fleet(true), writable: true)
      mobile_paused = paused |> Floki.parse_document!() |> Floki.find("#global-pause-toggle-mobile")

      assert Floki.attribute(mobile_paused, "aria-pressed") == ["true"]
      assert Floki.attribute(mobile_paused, "class") |> List.first() =~ "is-paused"

      readonly = render_payload(global_pause_fleet(false), writable: false)
      mobile_readonly = readonly |> Floki.parse_document!() |> Floki.find("#global-pause-toggle-mobile")

      assert Floki.attribute(mobile_readonly, "aria-disabled") == ["true"]
    end

    # `.global-pause-icon` shipped with no stylesheet rule, so the inline SVG —
    # which carries no intrinsic dimensions — collapsed and the button rendered
    # as an empty circle on every breakpoint. Guard the whole class of bug: any
    # icon wrapper the shell renders must have its SVG sized in dashboard.css.
    test "every icon wrapper in the shell has an svg sizing rule" do
      css = File.read!(Path.expand("../../../priv/static/dashboard.css", __DIR__))

      wrapper_classes =
        global_pause_fleet(false)
        |> render_payload(writable: true)
        |> Floki.parse_document!()
        |> Floki.find(".dashboard-shell span[class$='-icon']")
        |> Enum.flat_map(&Floki.attribute([&1], "class"))
        |> Enum.uniq()

      assert wrapper_classes != [], "expected the shell to render icon wrappers"

      for class <- wrapper_classes do
        assert Regex.match?(~r/\.#{Regex.escape(class)}\s+svg\s*\{[^}]*\bwidth\s*:/, css),
               "#{class} renders an inline SVG but dashboard.css has no `.#{class} svg { width: ... }` rule, so it collapses to nothing"
      end
    end
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

    assert html =~ "No active units"
    refute html =~ "MT-900"
    refute html =~ "Idle review"
  end

  test "refreshes a dashboard only after an orchestrator projection completes" do
    orchestrator_name = Module.concat(__MODULE__, :ProjectedDashboardOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5, control_center_cache: false)
    {:ok, view, initial_html} = live(build_conn(), "/")
    # Before the first snapshot the fleet area degrades to its ordinary empty
    # state, which names the missing fleet view rather than claiming the run is
    # empty. No notice, no error card.
    assert initial_html =~ "No live units. Fleet data is unavailable."
    refute initial_html =~ "snapshot_unpublished"
    refute initial_html =~ "No fleet data"

    :ok = ObservabilityPubSub.subscribe()
    :sys.replace_state(pid, &%{&1 | snapshot_ready?: true})
    :ok = StatusReport.notify_dashboard(:sys.get_state(pid))

    refute_receive {:observability_updated, _event_id}, 20
    assert_receive {:observability_updated, _event_id}, 1_000
    assert eventually(fn -> not String.contains?(render(view), "while the fleet snapshot is unavailable") end, 100)
  end

  test "an unpublished snapshot raises no notice while an unreachable orchestrator does" do
    # The post-restart moment before the first snapshot is expected, and the
    # Units catalog underneath already reports the missing fleet view, so the
    # notice is pure noise. A genuine fault still gets its card.
    unpublished =
      render_component(&Overview.error/1, error: %{code: "snapshot_unpublished", message: "No fleet snapshot published yet"})

    unavailable =
      render_component(&Overview.error/1, error: %{code: "orchestrator_unavailable", message: "Orchestrator is unavailable"})

    assert String.trim(unpublished) == ""

    assert unavailable =~ "No fleet data"
    assert unavailable =~ "there is no earlier fleet data to show"
  end

  test "a read-model fault never claims the orchestrator is unreachable" do
    # `snapshot_unavailable` is raised by the read-model composition, not by the
    # Orchestrator. Asserting an unobserved subsystem is the exact defect that
    # put "current-run membership is healthy" next to "Snapshot unavailable".
    read_model_fault =
      render_component(&Overview.error/1, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"})

    assert read_model_fault =~ "Could not read the fleet"
    assert read_model_fault =~ "fleet view could not be built"
    assert read_model_fault =~ "may still be running"
    refute read_model_fault =~ "The Orchestrator is not reachable"

    unknown_fault = render_component(&Overview.error/1, error: %{code: "something_else", message: "Unmapped fault"})
    refute unknown_fault =~ "The Orchestrator is not reachable"
    assert unknown_fault =~ "something_else"
  end

  test "a stalled orchestrator's stale label names the stall, not a busy mailbox" do
    html =
      render_component(&Overview.stale_label/1,
        freshness: %{status: :stale, reason: :snapshot_stalled, age_seconds: 7_440}
      )

    assert html =~ "Not live"
    assert html =~ "The Orchestrator has stopped publishing."
    assert html =~ "2h 4m old"
    refute html =~ "The Orchestrator is busy."
  end

  test "a stale fleet snapshot carries its age with last-known-good vocabulary" do
    html =
      render_component(&Overview.stale_label/1,
        freshness: %{status: :stale, reason: :snapshot_timeout, age_seconds: 95}
      )

    assert html =~ "Not live"
    assert html =~ "Showing the fleet as we last saw it"
    assert html =~ "1m 35s old"
    # The contradiction the operator reported: never unavailable and healthy at once.
    refute html =~ "unavailable"
  end

  test "labels stale timeout and unavailable snapshots differently" do
    timeout_html =
      render_component(&Overview.stale_label/1,
        freshness: %{status: :stale, reason: :snapshot_timeout, age_seconds: 6}
      )

    unavailable_html =
      render_component(&Overview.stale_label/1,
        freshness: %{status: :stale, reason: :orchestrator_unavailable, age_seconds: 6}
      )

    assert timeout_html =~ "Orchestrator is busy"
    assert unavailable_html =~ "Orchestrator is unavailable"
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

    assert length(Floki.find(Floki.parse_document!(unavailable_units), ~s(nav[aria-label^="Aiur"]))) == 2
    assert length(Floki.find(Floki.parse_document!(unavailable_units), ~s(a[aria-current="page"]))) == 2
    assert Floki.parse_document!(unavailable_units) |> Floki.find("h1#route-title") |> Floki.text() =~ "Units"
    assert unavailable_units =~ ~s(href="/analytics")
    assert unavailable_units =~ ~s(href="/build-orders")
    assert unavailable_units =~ ~s(data-phx-link="redirect")
    # Scope to nav anchors: the global-pause toggle is a button that is
    # legitimately disabled in this read-only render, and is not a nav route.
    assert Floki.find(Floki.parse_document!(unavailable_units), ~s(a[aria-disabled="true"])) == []

    assert available_units =~ ~s(href="/analytics")
    assert Floki.find(Floki.parse_document!(available_units), ~s(a[aria-disabled="true"])) == []

    assert Floki.parse_document!(commands) |> Floki.find("h1#route-title") |> Floki.text() =~ "Commands"
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
    assert inbox_html =~ ~s(href="/commands/dec-safe-link")
    assert inbox_html =~ "Commands inbox"
    refute inbox_html =~ ~s(id="recent-title")
    assert detail_html =~ "Recorded"
    assert detail_html =~ "Event timeline"
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
        awaiting: 73,
        awaiting_blocking: 4,
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

    assert html =~ "73 units awaiting commands"
    assert html =~ "Issue commands"
    assert html =~ "Partial Command counts"
    assert html =~ "Partial Command data"
  end

  test "cannot render an empty Units body while the same payload reports current agents and Commands" do
    identity = units_identity()
    fleet_payload = Map.put(units_orchestrator_snapshot(identity), :generated_at, "2026-07-17T12:00:00Z")

    payload =
      ControlCenterPresenter.state_payload(
        :unused,
        1,
        fleet_fun: fn -> fleet_payload end,
        decisions_fun: fn -> [] end
      )
      |> Map.put(:retained_counts, %{
        open: 3,
        blocking: 0,
        awaiting: 3,
        awaiting_blocking: 0,
        scope: %{kind: :retained, label: "All retained decisions"},
        health: %{status: :healthy, partial?: false, label: "Retained Decision data"}
      })
      |> then(fn payload ->
        Map.put(
          payload,
          :units,
          UnitsPresenter.load(payload,
            membership_fun: fn -> %{units_membership(identity) | members: []} end,
            activity_fun: fn -> %{entries: []} end
          )
        )
      end)

    html = render_payload(fleet_payload, payload: payload)

    assert html =~ "3 units awaiting commands"
    assert html =~ ~s(id="units-rows")
    assert html =~ "Responsive Units interface"
    refute html =~ "No units in this run yet in this run"
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
    assert html =~ "may exist in a part we cannot read"
    refute html =~ "No retained Command matches"
    refute html =~ "Some of this detail may be missing"
  end

  test "keeps durable outcomes off the Units page during a snapshot outage" do
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

    assert html =~ "orchestrator_unavailable"
    refute html =~ "Merged this run"
    refute html =~ "from the current run"
    refute html =~ "Command history"
    refute html =~ "Executor"
    refute html =~ "Supervising agent"
    refute html =~ "&lt;script&gt;alert"
    refute html =~ "<script>alert"
    refute html =~ "Recent repository merges"
    refute html =~ "Observed live"
    refute html =~ "Observer run run-observer"
    refute html =~ "No ticket attribution"
    refute html =~ "5-page cap"
    refute html =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute html =~ "<img src=x"
    assert html =~ ~s(href="/analytics")
    refute html =~ "Open analytics report"
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

  describe "current-run outcomes (DASH-034)" do
    test "does not render current-run outcomes on the Units destination" do
      view = start_outcomes_dashboard()
      html = push_outcomes(view, healthy_outcomes_snapshot(numbers: [42, 7]))

      refute html =~ "Finished this run"
      refute html =~ "Current run"
      refute html =~ "Repository merges from this run"
      refute html =~ ~s(id="current-run-outcomes")
      refute html =~ "PR #42"
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
      refute render(view) =~ ~s(id="current-run-outcomes")
    end
  end

  test "unconfigured dashboard authentication refuses the dashboard route with its cause" do
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

    response = get(Phoenix.ConnTest.build_conn(), "/")

    assert response.status == 503
    assert response.resp_body =~ "Dashboard authentication is not configured"
    refute response.resp_body =~ sentinel
  end

  test "a revoked financial session renders a locked capability without leaking financial sentinels" do
    orchestrator_name = Module.concat(__MODULE__, :RevokedFinancialBoundaryOrchestrator)
    sentinel = "acct-plan-quota-reset-financial-sentinel"
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "boundary-secret")

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
      dashboard_auth_required: true,
      dashboard_writable: false
    )

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:boundary-secret"))

    test_process = self()

    log =
      capture_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        socket = :sys.get_state(view.pid).socket
        assert socket.assigns.financial_data_capability.state == :authorized

        # Rotate credentials: the outstanding session marker is now stale, so
        # the next mount sees no valid financial access and renders locked.
        System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-boundary-secret")

        {:ok, redirected, redirected_html} = live_redirect(view, to: "/commands")
        send(test_process, {:revoked_financial, redirected})
        assert redirected_html =~ "Commands"
      end)

    assert_receive {:revoked_financial, redirected}, 2_000
    socket = :sys.get_state(redirected.pid).socket

    assert socket.assigns.financial_data_capability.state == :locked
    assert socket.assigns.payload.fleet.agent_totals == %{seconds_running: 41}
    refute Map.has_key?(socket.assigns.payload.fleet, :rate_limits)
    refute inspect(socket) =~ sentinel
    refute render(redirected) =~ sentinel
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

    unauthenticated = get(Phoenix.ConnTest.build_conn(), "/")
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

  test "authorized usage and cost panel opens the capability gate without leaking a locked state" do
    orchestrator_name = Module.concat(__MODULE__, :AuthorizedUsageOrchestrator)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "usage-panel-secret")

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

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:usage-panel-secret"))

    assert {:ok, view, _html} = live(conn, "/")
    socket = :sys.get_state(view.pid).socket

    # The gate opens: the panel is no longer locked. With no active run scope it
    # is a truthful empty state, never a synthetic zero total.
    assert socket.assigns.financial_data_capability.state == :authorized
    refute socket.assigns.usage_summary.state == :locked
    assert socket.assigns.usage_summary.state in [:empty, :ready, :partial, :stale, :unavailable]
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

    {:ok, view, _html} = live(build_conn(), "/commands")

    view
    |> element(~s(button[phx-click="filter-decisions"][phx-value-filter="blocking"]))
    |> render_click()

    assert_patch(view, "/commands?filter=blocking")

    view
    |> element("#decision-#{decision.decision_id} .decision-card-head")
    |> render_click()

    assert_patch(view, "/commands/#{decision.decision_id}?filter=blocking")

    view
    |> element("#decision-#{decision.decision_id} .decision-card-head")
    |> render_click()

    assert_patch(view, "/commands?filter=blocking")

    view
    |> element("#decision-#{decision.decision_id} .decision-card-head")
    |> render_click()

    assert_patch(view, "/commands/#{decision.decision_id}?filter=blocking")
    render_submit(view, "search-commands", %{"search" => decision.decision_id})
    assert_patch(view, "/commands?search=#{decision.decision_id}")
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

    {:ok, view, _html} = live(build_conn(), "/commands?ticket=11")

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

    {:ok, view, _html} = live(build_conn(), "/commands")

    view
    |> element(~s(button[phx-click="filter-decisions"][phx-value-filter="open"]))
    |> render_click()

    assert_patch(view, "/commands?filter=open")
    assert has_element?(view, ".decision-list #decision-#{human.decision_id}")
    assert has_element?(view, ".decision-list #decision-#{delegated.decision_id}")
  end

  test "All Commands keeps retained search and pagination controls out of the surface" do
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

    {:ok, view, html} = live(build_conn(), "/commands")

    refute html =~ "Search retained Commands"
    refute html =~ "Command ID or ticket ID"
    refute html =~ "Next page"
    refute html =~ "Final retained Command page"
    refute has_element?(view, "#decision-#{oldest.decision_id}")

    invalid_html = render_patch(view, "/commands?cursor=not-a-valid-cursor")
    assert invalid_html =~ "Commands are unavailable right now"
    assert Process.alive?(view.pid)
  end

  test "All Commands and the CLI show the same open set" do
    orchestrator_name = Module.concat(__MODULE__, :OpenPageOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :OpenPageDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_080}}}
      end)

    # Non-blocking: this fixture only needs historic rows to page over, and a
    # blocking Command cannot be closed without an answer.
    decisions =
      for index <- 0..26 do
        request_dashboard_decision(store, "open-page-#{index}", "reversible",
          blocking: false,
          now: DateTime.add(~U[2026-07-13 08:00:00Z], index, :second)
        )
      end

    Enum.each(Enum.drop(decisions, 2), fn decision ->
      assert {:ok, %{status: :accepted}} =
               DecisionStore.dismiss(
                 decision.decision_id,
                 [actor: %{kind: :operator, id: "dashboard"}],
                 store
               )
    end)

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false
    )

    {:ok, view, html} = live(build_conn(), "/commands")

    assert html =~ ~r/All\s+<span class="count num">2<\/span>/
    assert has_element?(view, "#decision-#{Enum.at(decisions, 0).decision_id}")
    assert has_element?(view, "#decision-#{Enum.at(decisions, 1).decision_id}")

    Enum.each(Enum.drop(decisions, 2), fn decision ->
      refute has_element?(view, "#decision-#{decision.decision_id}")
    end)

    assert {:ok, cli} =
             CommandsCLI.build(
               decision_store: decision_store_name,
               decision_metrics: make_ref(),
               history_fun: fn -> [] end
             )

    assert cli["data"]["page"]["decisions"]
           |> MapSet.new(& &1["decision_id"]) ==
             decisions
             |> Enum.take(2)
             |> MapSet.new(& &1.decision_id)
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

    {:ok, _view, html} = live(build_conn(), "/commands/#{oldest.decision_id}")
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

    {:ok, _view, html} = live(build_conn(), "/commands/#{resolved.decision_id}?filter=open")
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

      {:ok, view, html} = live(build_conn(), "/commands/#{overview.decision_id}")
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

      {:ok, view, html} = live(build_conn(), "/commands/#{overview.decision_id}")
      assert html =~ if(detail_status == :unavailable, do: "Command unavailable", else: "Command presence unknown")
      refute has_element?(view, "#decision-#{overview.decision_id}")
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

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    assert html =~ ~s(phx-submit="answer-decision")

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

  test "a non-selected Command stays answerable from another Command's detail page" do
    orchestrator_name = Module.concat(__MODULE__, :NonSelectedAnswerOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :NonSelectedAnswerStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 5_099}}}
      end)

    selected = request_dashboard_decision(store, "non-selected-detail")
    other = request_dashboard_decision(store, "non-selected-other-open")

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    # Opening one Command's detail page must not make the other Command
    # unanswerable: its inline form is still rendered and must reach the store.
    {:ok, view, html} = live(build_conn(), "/commands/#{selected.decision_id}")
    assert html =~ ~s(phx-submit="answer-decision")

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => other.decision_id,
        "answer" => %{"choice" => "option:ship", "rationale" => "Answering a non-selected Command"}
      })

    # The socket pre-check must not reject the answer: the false "no longer
    # open" claim would leave the Command open in the store.
    refute html =~ "is not loaded on this page"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(other.decision_id, store)
             current.answer.selected_option_id == "ship"
           end)

    assert {:ok, answered} = DecisionStore.get(other.decision_id, store)
    assert answered.decision_status == :decided
    assert answered.answer.rationale == "Answering a non-selected Command"

    # The selected Command was left untouched by the answer to the other one.
    assert {:ok, selected_current} = DecisionStore.get(selected.decision_id, store)
    assert is_nil(selected_current.answer)
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

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
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

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")
    add_newer_dashboard_decisions(store, decision, "stale-payload-answer-newer")
    refute Enum.any?(DecisionStore.recent_decisions(50, store), &(&1.decision_id == decision.decision_id))
    assert reload_view(view) =~ ~s(phx-submit="answer-decision")

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

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")
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

    {:ok, view, html} = live(build_conn(), "/commands/#{detail.decision_id}")
    assert html =~ "Destroy the active release?"
    assert html =~ "Destroy the active release"
    refute html =~ "I understand this Command is irreversible or destructive."
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

    {:ok, view, html} = live(build_conn(), "/commands/#{detail.decision_id}")
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

    {:ok, view, _html} = live(build_conn(), "/commands/#{initial.decision_id}")

    draft_html =
      render_change(view, "decision-action-change", %{
        "decision_id" => initial.decision_id,
        "answer" => %{
          "choice" => "custom",
          "custom_response" => "Draft from the old retained version"
        }
      })

    assert draft_html =~ "Draft from the old retained version"

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

    {:ok, view, _html} = live(build_conn(), "/commands/#{initial.decision_id}")

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

    {:ok, _view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")

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

    {:ok, _view, html} = live(build_conn(), "/commands/dec-retained-missing")
    assert html =~ "Command not found"
    assert html =~ "No retained Command matches dec-retained-missing."
    refute html =~ "Command unavailable"
  end

  test "malformed filter and agent-log events do not crash the dashboard" do
    orchestrator_name = Module.concat(__MODULE__, :MalformedEventOrchestrator)
    start_counting_orchestrator(orchestrator_name)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 100)

    {:ok, view, _html} = live(build_conn(), "/commands")

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

    # The delivery outcome is produced asynchronously: the store dispatches on
    # a background task, records the failure, and only then broadcasts
    # {:decision_changed, ...}, which the LiveView reflects through a payload
    # reload. The default reload path throttles that reload by
    # @reload_min_interval_ms (400ms), and under load the whole async chain
    # can outrun any wall-clock wait — the flake #1920 observed (fails
    # ~1-in-10 under load). render/1 already synchronizes with the LiveView
    # process (a ping that drains its mailbox), so removing the artificial
    # reload delay here is a real synchronization point: as soon as the store
    # records the failure, the next render reflects it. This uses the same
    # control_center_reload_timer hook the burst-throttle test relies on, and
    # changes no production timing.
    reload_timer = fn destination, message, _delay_ms ->
      send(destination, message)
      make_ref()
    end

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      dashboard_writable: true,
      control_center_reload_timer: reload_timer
    )

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    refute html =~ "Answer this Command"
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

    # render_submit returns the render produced by the submit handler itself,
    # before the async delivery-failure broadcast reaches the LiveView, so the
    # transient "Answer recorded" notice is still visible here. With the
    # immediate reload timer, the follow-up reload clears the notice as soon as
    # the failure lands — which is exactly what "Delivery failed" replaces it
    # with below.
    html = render_submit(view, "answer-decision", params)
    assert html =~ "Answer recorded"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(decision.decision_id, store)
             current.delivery_status == :failed
           end)

    # The delivery outcome is produced asynchronously: background dispatch task
    # -> store records the failure -> {:decision_changed, ...} broadcast. With
    # the immediate reload timer, render/1 (whose ping drains the LiveView
    # mailbox) reflects that failure on the next call, so this wait is
    # deterministic rather than a wall-clock guess at the whole async chain.
    assert eventually(fn -> render(view) =~ "Delivery failed" end, 100)
    html = render(view)
    assert html =~ "Recorded answer"
    assert html =~ "Delivery failed"
    assert html =~ ~s(phx-click="retry-decision")

    html = view |> element(~s(button[phx-click="retry-decision"])) |> render_click()
    assert html =~ "delivery retry was scheduled"

    assert eventually(fn ->
             {:ok, current} = DecisionStore.get(decision.decision_id, store)
             current.delivery_status == :queued
           end)

    assert eventually(fn -> not String.contains?(render(view), ~s(phx-click="retry-decision")) end, 100)

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &match?(%DecisionEvent{type: :answer_recorded}, &1)) == 1
    assert Enum.count(audit, &match?(%DecisionEvent{type: :failed}, &1)) == 1
    assert Enum.count(audit, &match?(%DecisionEvent{type: :dispatch_queued}, &1)) == 1
  end

  test "irreversible answers do not require a redundant confirmation" do
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

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    refute html =~ "I understand this Command is irreversible or destructive."

    params = %{
      "decision_id" => decision.decision_id,
      "answer" => %{"choice" => "option:ship"}
    }

    html = render_submit(view, "answer-decision", params)
    assert html =~ "Answer recorded"

    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer.selected_option_id == "ship"

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.any?(audit, &match?(%DecisionEvent{type: :answer_recorded}, &1))
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

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
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

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")

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

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")

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

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")

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

    {:ok, view, _html} = live(build_conn(), "/commands/#{decision.decision_id}")

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

    path = "/commands/#{decision.decision_id}"
    {:ok, view, html} = live(build_conn(), path)
    refute html =~ "Answer this Command"
    refute html =~ "Command latency"

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
    assert resolved_html =~ "Resolved"
    refute render(view) =~ "Command not found"

    root_html = render_patch(view, "/")
    refute root_html =~ "987"
    refute root_html =~ "Recent repository merges"
    refute root_html =~ "Command history"

    decisions_html = render_patch(view, "/commands")
    assert decisions_html =~ "Command history"
    assert decisions_html =~ "dashboard"

    detail_html = render_patch(view, path)
    assert detail_html =~ decision.decision_id
    assert detail_html =~ "Event timeline"
    assert detail_html =~ "Requested"
    refute detail_html =~ "Command not found"

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)

    assert Enum.map(audit, fn
             %Decision{} -> :requested
             %DecisionEvent{type: type} -> type
           end) == [:requested, :answer_recorded, :dispatch_queued, :delivered, :acknowledged, :resolved]
  end

  test "card-face deferral persists and publishes to the Executor without waking the ticket agent" do
    orchestrator_name = Module.concat(__MODULE__, :DismissCapstoneOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DismissCapstoneDecisionStore)
    orchestrator = start_queue_orchestrator(orchestrator_name, "987")
    store = start_decision_store(decision_store_name, fn _decision, _opts -> {:error, :unexpected_dispatch} end)
    live_decision = request_queue_decision(store, "dashboard-dismiss-live", "987")

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands")
    assert :ok = Exchange.subscribe("executor.#")
    assert html =~ ~s(phx-click="defer-decision")

    _html =
      view
      |> element("#decision-#{live_decision.decision_id} button[phx-click=\"defer-decision\"]")
      |> render_click()

    assert {:ok, deferred} = DecisionStore.get(live_decision.decision_id, store)
    assert deferred.decision_status == :deferred
    assert deferred.answer == nil
    assert_receive {:event, %{topic: "executor.decision.deferred", decision_id: decision_id, issue_identifier: "987", provenance: :operator_dashboard}}, 500
    assert decision_id == live_decision.decision_id
    assert :empty = OperatorMessages.claim_next_queue_item(orchestrator, "987")

    :sys.replace_state(orchestrator, &%{&1 | running: %{}})
    gone_decision = request_queue_decision(store, "dashboard-dismiss-gone", "988")
    {:ok, gone_view, _html} = live(build_conn(), "/commands")

    _html =
      gone_view
      |> element("#decision-#{gone_decision.decision_id} button[phx-click=\"defer-decision\"]")
      |> render_click()

    assert {:ok, gone_deferred} = DecisionStore.get(gone_decision.decision_id, store)
    assert gone_deferred.decision_status == :deferred
    refute_receive {:agent_queue_updated, "988", _queue_item_id, _delivery}, 200
    assert :empty = OperatorMessages.claim_next_checkpoint_queue_item(orchestrator, "988")
  end

  test "a deferred detail command remains answerable" do
    orchestrator_name = Module.concat(__MODULE__, :DeferredDetailOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DeferredDetailStore)
    store = start_decision_store(decision_store_name, fn _decision, _opts -> {:ok, %{status: :accepted, item: %{id: 5_074}}} end)
    decision = request_queue_decision(store, "deferred-detail", "987")

    start_counting_orchestrator(orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      decision_store: decision_store_name,
      control_center_cache: false,
      dashboard_writable: true
    )

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    assert html =~ ~s(phx-click="defer-decision")

    _html =
      view
      |> element("#decision-#{decision.decision_id} button[phx-click=\"defer-decision\"]")
      |> render_click()

    html =
      render_submit(view, "answer-decision", %{
        "decision_id" => decision.decision_id,
        "answer" => %{"choice" => "option:ship", "rationale" => "The Executor can still receive the final answer"}
      })

    assert html =~ "Answer recorded"
    assert {:ok, %{decision_status: :decided}} = DecisionStore.get(decision.decision_id, store)
  end

  test "free-form attention acknowledges without recording an answer" do
    orchestrator_name = Module.concat(__MODULE__, :AckFreeFormOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :AckFreeFormStore)
    store = start_decision_store(decision_store_name, fn _decision, _opts -> {:error, :unexpected_dispatch} end)

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{
          "source_id" => "dashboard-ack-free-form",
          "question" => "Heads up: the run finished.",
          "blocking" => false,
          "urgency" => "normal",
          "reversibility" => "reversible",
          "options" => []
        },
        [
          ticket: %{identifier: "987", title: "Operator Control Center", url: nil},
          source: %{agent_id: "agent-987", session_id: "session-987", event_id: "event-ack"}
        ],
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

    {:ok, view, html} = live(build_conn(), "/commands/#{decision.decision_id}")
    assert html =~ ~s(phx-click="dismiss-decision")

    html =
      view
      |> element("#decision-#{decision.decision_id} button[phx-click=\"dismiss-decision\"]")
      |> render_click()

    # The notice states what happened, not which affordance was used: the same
    # event backs the Acknowledge button and the blocker dismissal, so claiming
    # an acknowledgement here would be false on the other route.
    assert html =~ "Command closed without a recorded answer."
    refute html =~ "acknowledged"
    assert {:ok, dismissed} = DecisionStore.get(decision.decision_id, store)
    assert dismissed.decision_status == :dismissed
    assert dismissed.answer == nil
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

    path = "/commands/#{decision.decision_id}"
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

    # `:agent_queue_updated` is broadcast by the dispatch task while it is still
    # enqueueing; the store only records `:revision_dispatched` once that task
    # reports back. Await the store's own transition instead of reading through
    # the queue signal.
    assert {:ok, revision_queued} = await_dispatched_revision(store, decision.decision_id)
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
    assert detail_html =~ "Event timeline"

    root_html = render_patch(view, "/")
    refute root_html =~ "Command history"

    decisions_html = render_patch(view, "/commands")
    assert decisions_html =~ "Command history"
    assert decisions_html =~ "Hold deployment until the incident closes"
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

    path = "/commands/#{decision.decision_id}"
    {:ok, view, initial_html} = live(build_conn(), path)

    assert initial_html =~ "Hold the cached rollout"
    assert initial_html =~ "Revision 1"
    refute initial_html =~ "Command latency"
    refute_receive {:dashboard_payload_loaded, ^orchestrator, _count}
    drain_dashboard_payload_notifications(orchestrator)
    assert :ok = DecisionPubSub.subscribe()

    for event <- [request_event, answer_event, revision_event] do
      assert :ok = DecisionMetrics.observe(event, metrics)
      assert_receive :decision_metrics_changed, 2_000
    end

    refute_receive {:dashboard_payload_loaded, ^orchestrator, _count}
    converged_html = render(view)
    refute converged_html =~ "Command latency"
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

    path = "/commands/#{decision.decision_id}"
    conn = get(build_conn(), path)
    disconnected_html = html_response(conn, 200)

    assert disconnected_html =~ "Recorded answer"
    refute disconnected_html =~ "Command latency"
    assert :ok = DecisionPubSub.subscribe()

    send(seed_process, :release_metrics_seed)
    assert :ok = DecisionMetrics.await_seed(metrics)
    assert_receive :decision_metrics_changed, 2_000
    refute_receive :decision_metrics_changed, 50

    {:ok, _view, connected_html} = live(conn)
    refute connected_html =~ "Command latency"
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

    {:ok, view, human_html} = live(build_conn(), "/commands/#{human.decision_id}")
    refute human_html =~ "Human required"

    assert {:error, {:delegation_forbidden, %{reasons: [:human_required]}}} =
             DecisionApi.decide(human.decision_id, supervisor_decision_payload(1), api_opts)

    assert {:ok, current_human} = DecisionStore.get(human.decision_id, store)
    assert current_human.decision_status == :open
    assert is_nil(current_human.answer)

    delegated_path = "/commands/#{delegated.decision_id}"
    delegated_html = render_patch(view, delegated_path)
    assert delegated_html =~ ~s(phx-submit="answer-decision")

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
    refute root_html =~ "Command history"

    decisions_html = render_patch(view, "/commands")
    assert decisions_html =~ "Command history"

    _filtered_html = render_patch(view, "/commands?filter=supervisor")
    filtered_list = view |> element(".decision-list") |> render()
    assert filtered_list =~ delegated.question
    refute filtered_list =~ human.question
  end

  test "paginates Command history ten rows at a time instead of rendering every resolved Command" do
    orchestrator_name = Module.concat(__MODULE__, :BoundedHistoryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :BoundedHistoryDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 507}}}
      end)

    start_counting_orchestrator(orchestrator_name)

    for index <- 1..25 do
      decision = request_dashboard_decision(store, "history-#{index}")

      assert {:ok, %{status: :accepted}} =
               DecisionStore.answer(
                 decision.decision_id,
                 %{
                   "idempotency_key" => "history-answer-#{index}",
                   "expected_version" => decision.version,
                   "option_id" => "ship"
                 },
                 [actor: %{kind: :operator, id: "operator"}],
                 store
               )
    end

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    assert history_row_count(view) == 10
    assert render(view) =~ "10 of 25"

    view |> element(~s(button[phx-click="load-more-history"])) |> render_click()
    assert history_row_count(view) == 20

    view |> element(~s(button[phx-click="load-more-history"])) |> render_click()
    assert history_row_count(view) == 25
    refute has_element?(view, ~s(button[phx-click="load-more-history"]))
  end

  test "an answered Command leaves the inbox and appears in green history" do
    orchestrator_name = Module.concat(__MODULE__, :DismissToHistoryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DismissToHistoryDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 508}}}
      end)

    start_counting_orchestrator(orchestrator_name)
    decision = request_dashboard_decision(store, "dismiss-to-history")

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    assert has_element?(view, "#decision-#{decision.decision_id}")
    assert history_row_count(view) == 0

    view
    |> form("#decision-answer-form-#{decision.decision_id}", %{"answer" => %{"choice" => "option:ship"}})
    |> render_submit()

    refute has_element?(view, "#decision-#{decision.decision_id}")
    assert has_element?(view, "#history-#{decision.decision_id}")
    assert history_row_count(view) == 1

    row = view |> render() |> Floki.parse_document!() |> Floki.find("#history-#{decision.decision_id}")
    assert Floki.attribute(row, "data-severity") == ["good"]
    assert row |> Floki.text() =~ "Answered"
  end

  test "expands a history row in place and quotes the answer the operator recorded" do
    orchestrator_name = Module.concat(__MODULE__, :HistoryAccordionOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :HistoryAccordionDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 510}}}
      end)

    start_counting_orchestrator(orchestrator_name)
    answered = request_dashboard_decision(store, "history-accordion")

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(
               answered.decision_id,
               %{
                 "idempotency_key" => "history-accordion-answer",
                 "expected_version" => answered.version,
                 "custom_response" => "it is the executor's job to review"
               },
               [actor: %{kind: :operator, id: "operator"}],
               store
             )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    row = view |> render() |> Floki.parse_document!() |> Floki.find("#history-#{answered.decision_id}")
    assert row |> Floki.text() =~ "“it is the executor's job to review”"
    assert row |> Floki.find("button.history-row-toggle") |> Floki.attribute("aria-expanded") == ["false"]
    refute has_element?(view, "#history-detail-history-#{answered.decision_id}")

    # Clicking the row is what opens it; the Command's own context arrives
    # inline, and no card is hoisted to the top of the page.
    view |> element("#history-#{answered.decision_id}") |> render_click()

    assert has_element?(view, "#history-detail-history-#{answered.decision_id}")
    assert has_element?(view, "#history-#{answered.decision_id} button[aria-expanded='true']")
    assert has_element?(view, "#history-detail-history-#{answered.decision_id} #decision-detail-#{answered.decision_id}")
    refute has_element?(view, ".decision-list #decision-#{answered.decision_id}")

    view |> element("#history-#{answered.decision_id}") |> render_click()
    refute has_element?(view, "#history-detail-history-#{answered.decision_id}")
  end

  test "refreshes a history row in place when the store revises the Command behind it" do
    orchestrator_name = Module.concat(__MODULE__, :HistoryRefreshOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :HistoryRefreshDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 512}}}
      end)

    start_counting_orchestrator(orchestrator_name)
    decision = request_dashboard_decision(store, "history-refresh")

    assert {:ok, %{status: :accepted, action: original}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "idempotency_key" => "history-refresh-original",
                 "expected_version" => decision.version,
                 "custom_response" => "ship the original answer"
               },
               [actor: %{kind: :operator, id: "operator"}],
               store
             )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    assert render(view) =~ "“ship the original answer”"

    # Somebody else revises the Command while the row is already on screen. The
    # loaded row must not keep asserting the answer it was loaded with.
    assert {:ok, %{status: :accepted}} =
             DecisionStore.revise(
               decision.decision_id,
               %{
                 "idempotency_key" => "history-refresh-revision",
                 "expected_version" => decision.version,
                 "expected_action_id" => original.action_id,
                 "expected_revision_sequence" => 0,
                 "custom_response" => "no, the executor reviews it",
                 "rationale" => "The first answer was wrong"
               },
               [actor: %{kind: :operator, id: "operator"}],
               store
             )

    assert eventually(fn -> render(view) =~ "“no, the executor reviews it”" end, 100)
    refute render(view) =~ "“ship the original answer”"
    assert history_row_count(view) == 1
  end

  test "keeps a deep-linked Command readable when history has not loaded its page" do
    orchestrator_name = Module.concat(__MODULE__, :DeepLinkHistoryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DeepLinkHistoryDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 513}}}
      end)

    start_counting_orchestrator(orchestrator_name)

    # One page of history plus one older Command: the deep-linked row sits
    # beyond the ten rows the first page loads.
    answered =
      for index <- 1..11 do
        decision = request_dashboard_decision(store, "deep-link-#{index}")

        assert {:ok, %{status: :accepted}} =
                 DecisionStore.answer(
                   decision.decision_id,
                   %{
                     "idempotency_key" => "deep-link-answer-#{index}",
                     "expected_version" => decision.version,
                     "option_id" => "ship"
                   },
                   [actor: %{kind: :operator, id: "operator"}],
                   store
                 )

        decision
      end

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")
    assert history_row_count(view) == 10

    unloaded =
      Enum.find(answered, fn decision ->
        not has_element?(view, "#history-#{decision.decision_id}")
      end)

    refute is_nil(unloaded), "expected one answered Command outside the first history page"

    {:ok, deep_linked, _html} = live(build_conn(), "/commands/#{unloaded.decision_id}")

    # No row to expand, so the card is still the only way to read it.
    refute has_element?(deep_linked, "#history-detail-history-#{unloaded.decision_id}")
    assert has_element?(deep_linked, "#decision-#{unloaded.decision_id}")
    refute render(deep_linked) =~ "Command not found"
  end

  test "reports an expired Command as having no decision at all" do
    orchestrator_name = Module.concat(__MODULE__, :ExpiredHistoryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :ExpiredHistoryDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 511}}}
      end)

    start_counting_orchestrator(orchestrator_name)
    expired = request_dashboard_decision(store, "history-expired", "reversible", blocking: false)

    assert {:ok, _expired} =
             DecisionStore.expire(expired.decision_id, "agent_not_running", [], store)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    row = view |> render() |> Floki.parse_document!() |> Floki.find("#history-#{expired.decision_id}")

    assert row |> Floki.find("td.history-decision") |> Floki.text() == "N/A"
    assert row |> Floki.text() =~ "Expired"
  end

  test "notifying the Executor moves the Command to history without flattening it into an answer" do
    orchestrator_name = Module.concat(__MODULE__, :DeferToHistoryOrchestrator)
    decision_store_name = Module.concat(__MODULE__, :DeferToHistoryDecisionStore)

    store =
      start_decision_store(decision_store_name, fn _decision, _opts ->
        {:ok, %{status: :accepted, item: %{id: 509}}}
      end)

    start_counting_orchestrator(orchestrator_name)
    decision = request_dashboard_decision(store, "defer-to-history")

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      decision_store: decision_store_name
    )

    {:ok, view, _html} = live(build_conn(), "/commands")

    view
    |> element(~s(button[phx-click="defer-decision"][phx-value-decision-id="#{decision.decision_id}"]))
    |> render_click()

    refute has_element?(view, "#decision-#{decision.decision_id}")
    assert has_element?(view, "#history-#{decision.decision_id}")

    row = view |> render() |> Floki.parse_document!() |> Floki.find("#history-#{decision.decision_id}")
    assert row |> Floki.text() =~ "Deferred to Executor"
    refute row |> Floki.text() =~ "Answered"
  end

  defp history_row_count(view) do
    view |> render() |> Floki.parse_document!() |> Floki.find("#command-history-rows tr.history-row") |> length()
  end

  test "round-trips validated Units URL state and exposes a named zero-result reset" do
    identity = units_identity()
    membership = units_membership(identity)
    orchestrator_name = Module.concat(__MODULE__, :UnitsURLOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end
    )

    # The compact filter bar exposes a single `unfinished` scope toggle plus the
    # bulk All/None controls; scope/condition state still round-trips through the
    # URL exactly as before.
    {:ok, view, html} = live(build_conn(), "/?v=1&scope=unfinished&conditions=active")

    assert html =~ "Responsive Units interface"
    assert has_element?(view, ~s(button[phx-value-scope="unfinished"][aria-pressed="true"]))
    assert has_element?(view, ~s(button[phx-value-condition="active"][aria-pressed="true"]))

    view
    |> element(~s(button[phx-value-condition="paused"]))
    |> render_click()

    assert_patch(view, "/?v=1&scope=unfinished&conditions=active%2Cpaused")
    assert has_element?(view, ~s(button[phx-value-condition="active"][aria-pressed="true"]))
    assert has_element?(view, ~s(button[phx-value-condition="paused"][aria-pressed="true"]))

    # Bulk "None" clears scope + conditions to the empty selection, which yields
    # zero rows and surfaces the named reset affordance.
    view
    |> element(~s(button[phx-click="select-no-units-filters"]))
    |> render_click()

    assert_patch(view, "/?v=1&scope=none")
    assert has_element?(view, ~s(button[phx-click="reset-units-filters"]), "Reset Units filters")

    view
    |> element(~s(button[phx-click="reset-units-filters"]))
    |> render_click()

    assert_patch(view, "/?v=1")
    refute has_element?(view, ~s(button[phx-value-scope="unfinished"][aria-pressed="true"]))
    assert has_element?(view, "#units-rows .units-row")

    invalid_html = render_patch(view, "/?v=999&scope=none&conditions=finished")
    assert invalid_html =~ "Responsive Units interface"
    assert_patch(view, "/?v=1")
    refute has_element?(view, ~s(button[phx-value-scope="unfinished"][aria-pressed="true"]))
    refute has_element?(view, ~s(button[phx-value-condition="finished"][aria-pressed="true"]))

    render_hook(view, "table-sort-changed", %{"sort" => "units:latest:desc"})

    view
    |> element(~s(button[phx-value-condition="active"]))
    |> render_click()

    assert_patch(view, "/?v=1&conditions=active&sort=units%3Alatest%3Adesc")

    render_patch(view, "/?v=1&sort=units%3Acommand%3Adesc")
    assert_patch(view, "/?v=1")
  end

  test "keeps valid Units selection and stable typed row identity across catalog updates" do
    identity = units_identity()
    {:ok, membership} = Agent.start_link(fn -> units_membership(identity) end)
    {:ok, activity} = Agent.start_link(fn -> units_activity(identity) end)
    orchestrator_name = Module.concat(__MODULE__, :UnitsUpdateOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

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

    # `all` scope has no dedicated button in the compact filter bar, but the
    # URL-provided selection persists across catalog updates — proven by the
    # now-terminal row (visible only under `scope=all`) remaining present with
    # its stable typed identity.
    assert has_element?(view, "##{row_id}")
    updated_html = render(view)
    assert has_element?(view, "##{row_id} .ut-pbar")
    assert has_element?(view, "##{row_id}", "75%")

    updated_announcement = updated_html |> Floki.parse_document!() |> Floki.find("#units-status") |> Floki.text()
    refute updated_announcement == initial_announcement
    assert updated_announcement =~ ~r/Update [a-f0-9]{10}/
  end

  test "opens shared ticket context only after explicit inspection and gates updates by typed identity" do
    identity = units_identity()
    membership = units_membership(identity)
    orchestrator_name = Module.concat(__MODULE__, :UnitsContextOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()
    {:ok, subscription_attempts} = Agent.start_link(fn -> 0 end)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

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

    html = view |> element(~s(td.ut-id-cell[phx-click="inspect-unit"])) |> render_click()

    assert_receive {:detail_subscribed, ^identity, 1}
    assert_receive {:history_subscribed, ^identity}
    assert_receive {:detail_requested, ^identity}
    assert_receive {:history_requested, ^identity}
    assert html =~ ~s(id="units-ticket-context")
    assert html =~ "Ticket context"
    assert html =~ "Responsive Units interface"
    assert html =~ "Open in GitHub"
    assert html =~ "Chat is unavailable"
    assert html =~ "Commands"
    refute html =~ "/private/workspace"

    other = units_identity(provider_id: "NODE-other", identifier: "1111")
    send(view.pid, {:ticket_detail_updated, units_ticket_detail(other, "Wrong ticket")})
    refute render(view) =~ "Wrong ticket"

    send(view.pid, {:ticket_detail_updated, units_ticket_detail(identity, "Updated ticket context")})
    assert render(view) =~ "Updated ticket context"

    view |> element("#units-ticket-context .ticket-context-close") |> render_click()
    refute_receive {:detail_unsubscribed, ^identity}
    assert_receive {:history_unsubscribed, ^identity}
    refute has_element?(view, "#units-ticket-context")

    html = view |> element(~s(td.ut-id-cell[phx-click="inspect-unit"])) |> render_click()
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

    replace_counting_snapshot(orchestrator, units_conversation_snapshot(identity, handle))

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
    assert html =~ "Open chat"
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

    replace_counting_snapshot(orchestrator, units_conversation_snapshot(identity, handle))

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

    html = view |> element(~s(td.ut-id-cell[phx-click="inspect-unit"])) |> render_click()

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

    replace_counting_snapshot(orchestrator, units_conversation_snapshot(identity, handle))

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

    replace_counting_snapshot(orchestrator, units_conversation_snapshot(identity, handle))

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

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

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
      render_hook(view, "show-agent-log", %{"unit" => token})

    assert html =~ ~s(phx-submit="send-operator-message")

    render_submit(view, "send-operator-message", %{"message" => "typed hello"})
    assert_receive {:typed_agent_message, ^identity, "typed hello"}

    render_hook(view, "pause-agent", %{})
    assert_receive {:typed_agent_pause, ^identity}
  end

  test "the chat modal composer carries the writable agent log and passes the typed Unit identity" do
    identity = units_identity()
    membership = units_membership(identity)
    handle = conversation_handle_value("c")
    orchestrator_name = Module.concat(__MODULE__, :TypedConversationComposerOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    snapshot = units_orchestrator_snapshot(identity)

    running =
      snapshot.running
      |> hd()
      |> Map.merge(%{
        live_conversation: %{generation_handle: handle, state: :live, health: :healthy, freshness: :current},
        workspace_path: Path.join(System.tmp_dir!(), "units-chat-composer-log")
      })

    replace_counting_snapshot(orchestrator, %{snapshot | running: [running]})

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      live_conversation_resolve_fun: fn _handle -> {:ok, conversation_snapshot(handle)} end,
      live_conversation_subscribe_fun: fn _handle -> :ok end,
      agent_chat_send_fun: fn selected, text ->
        send(test_pid, {:drawer_agent_message, selected, text})
        {:ok, 9}
      end,
      agent_chat_pause_fun: fn selected ->
        send(test_pid, {:drawer_agent_pause, selected})
        {:ok, 10}
      end
    )

    {:ok, view, _html} = live(build_conn(), "/")

    html = view |> element(~s(button[phx-click="read-conversation"])) |> render_click()

    assert html =~ ~s(phx-submit="send-operator-message")
    assert html =~ "Agent log"

    render_submit(view, "send-operator-message", %{"message" => "drawer hello"})
    assert_receive {:drawer_agent_message, ^identity, "drawer hello"}

    render_hook(view, "pause-agent", %{})
    assert_receive {:drawer_agent_pause, ^identity}
  end

  describe "unit controls (DASH-005)" do
    test "pauses an eligible unit through DASH-004 and mirrors applied evidence only" do
      %{view: view, token: token} =
        start_unit_control(:PauseAppliedOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_caps, "1110"}
      assert_receive {:unit_pause, "1110"}
      assert html =~ "Pause requested"
      refute html =~ "tone-applied"

      send(view.pid, {:control_lifecycle, lifecycle(:pause, :applied, 8)})
      html = render(view)
      assert html =~ "Paused"
      assert html =~ "tone-applied"
      # The control button keeps its stable id across the lifecycle re-render, so
      # LiveView preserves keyboard focus on it.
      assert html =~ ~s(id="units-control-#{token}")
    end

    test "resumes an applied-paused unit and correlates the resume lifecycle" do
      %{view: view, token: token} =
        start_unit_control(:ResumeOrchestrator,
          work_state: :paused,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :paused, pending_control: nil}} end,
          resume: {:ok, :resumed}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "resume"})
      assert_receive {:unit_resume, "1110"}
      assert html =~ "Resume requested"

      send(view.pid, {:control_lifecycle, lifecycle(:resume, :applied, 21)})
      assert render(view) =~ "Resumed"
    end

    test "fails closed and never invokes DASH-004 when the dashboard is read-only" do
      %{view: view, token: token, html: html} =
        start_unit_control(:ReadOnlyControlOrchestrator,
          writable: false,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      assert html =~ ~s(aria-disabled="true")
      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      refute_receive {:unit_caps, _}
      refute_receive {:unit_pause, _}
    end

    test "debounces duplicate activation while a request is pending" do
      %{view: view, token: token} =
        start_unit_control(:DebounceOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_caps, "1110"}
      assert_receive {:unit_pause, "1110"}

      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      refute_receive {:unit_pause, "1110"}
      refute_receive {:unit_caps, "1110"}
    end

    test "renders request-only distinctly and does not invoke the owner" do
      %{view: view, token: token} =
        start_unit_control(:RequestOnlyOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :request_only, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_caps, "1110"}
      refute_receive {:unit_pause, _}
      assert html =~ "request-only"
      refute html =~ "tone-applied"
    end

    test "an unsupported worker is visibly distinct and never invoked" do
      %{view: view, token: token} =
        start_unit_control(:UnsupportedOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :unsupported, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      refute_receive {:unit_pause, _}
      assert html =~ "unsupported"
    end

    test "a concurrent state change cancels the request without invoking the owner" do
      %{view: view, token: token} =
        start_unit_control(:StateChangeOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :paused, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      refute_receive {:unit_pause, _}
      assert html =~ "state changed"
    end

    test "a stale-generation rejection cancels stale intent rather than masquerading as applied" do
      %{view: view, token: token} =
        start_unit_control(:StaleGenerationOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_pause, "1110"}

      send(view.pid, {:control_lifecycle, lifecycle(:pause, :rejected, 8, %{class: :stale_generation})})
      html = render(view)
      refute html =~ "tone-applied"
      assert html =~ "canceled"
    end

    test "a concurrent terminal transition cancels stale in-flight intent on reload" do
      identity = units_identity()
      orchestrator_name = Module.concat(__MODULE__, :TerminalReconcileOrchestrator)
      orchestrator = start_counting_orchestrator(orchestrator_name)
      test_pid = self()
      {:ok, membership_agent} = Agent.start_link(fn -> units_membership(identity) end)

      replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

      start_test_endpoint(
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 100,
        control_center_cache: false,
        dashboard_writable: true,
        units_membership_fun: fn -> Agent.get(membership_agent, & &1) end,
        units_activity_fun: fn -> units_activity(identity) end,
        agent_chat_capabilities_fun: fn _id ->
          {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}}
        end,
        agent_chat_pause_fun: fn id ->
          send(test_pid, {:unit_pause, id})
          {:ok, 8}
        end
      )

      {:ok, view, _html} = live(build_conn(), "/")
      token = UnitsPresenter.row_token(%{identity: identity})

      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_pause, "1110"}
      assert render(view) =~ "Pause requested"
      assert control_status(view, token) == :requested

      # The unit goes terminal before any applied evidence arrives; a reload must
      # cancel the stale intent rather than let it settle or masquerade as applied.
      terminal = put_in(units_membership(identity), [:members, Access.at(0), :terminal?], true)
      Agent.update(membership_agent, fn _prev -> terminal end)
      send(view.pid, :reload_payload)
      _ = render(view)

      assert control_status(view, token) == :state_changed
    end

    test "a timeout leaves the last state visible with a named retry" do
      %{view: view, token: token} =
        start_unit_control(:TimeoutOrchestrator,
          capabilities: fn -> {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}} end,
          pause: {:ok, 8}
        )

      render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      assert_receive {:unit_pause, "1110"}

      send(view.pid, {:control_lifecycle, lifecycle(:pause, :expired, 8)})
      html = render(view)
      assert html =~ "timed out"
      assert html =~ "tone-error"
    end

    test "a control provider failure surfaces a named error and safe retry" do
      %{view: view, token: token} =
        start_unit_control(:ProviderFailureOrchestrator,
          capabilities: fn -> {:error, :unavailable} end,
          pause: {:ok, 8}
        )

      html = render_hook(view, "request-unit-control", %{"unit" => token, "action" => "pause"})
      refute_receive {:unit_pause, _}
      assert html =~ "retry"
      assert html =~ "tone-error"
    end
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
    replace_counting_snapshot(orchestrator, %{units_orchestrator_snapshot(alpha) | running: [alpha_row, beta_row]})

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
    replace_counting_snapshot(orchestrator, snapshot)

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
      render_hook(view, "show-agent-log", %{"unit" => token})

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

    assert html =~ "No active units"
    refute html =~ "Observed and selected-scope counts unavailable"
    assert html =~ "Count unavailable"
    assert html =~ ~s(aria-label="Count unavailable")
    refute html =~ "0 observed"
    refute html =~ "0 in selected scope"
  end

  test "the Agents panel titles and counts itself above the filter row" do
    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :AgentsHeaderOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot([]) end
    )

    {:ok, _view, html} = live(build_conn(), "/")

    # The same title/count pair the APIs and Models panels use.
    assert html =~ ~s(<span class="rs-group-title" id="units-title">Units</span>)
    assert html =~ ~s(<span class="rs-group-count">1 unit</span>)

    [_before, after_header] = String.split(html, "units-title", parts: 2)
    assert after_header =~ "units-filter-list"
  end

  test "the Tickets panel lists open tickets and opens detail and add-agent modals" do
    # Pin the routing table to an entry that names a backend but no model. That is
    # the case the modal used to get wrong: the requested model is nil, so the
    # select fell back to "Backend default" while the table's routing column named
    # the model that would really run. A bare test daemon routes to a backend with
    # no default at all, which would make the prefill assertions vacuous.
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), agent_routing: %{5 => "kimi"})

    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsPanelOrchestrator)
    test_pid = self()
    orchestrator = start_counting_orchestrator(orchestrator_name, report: test_pid)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot([open_ticket("2101", ["complexity:5"])]) end,
      add_agent_fun: fn identifier, label, action ->
        send(test_pid, {action, identifier, label})
        :ok
      end
    )

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "Tickets"
    assert html =~ "Unrouted backlog ticket"
    refute html =~ "ticket-detail-modal"

    view |> element(~s(td.tk-title-cell[phx-click="inspect-ticket"])) |> render_click()
    assert render(view) =~ "ticket-detail-modal"

    view |> element(~s(#ticket-detail-modal button[phx-click="close-ticket-detail"])) |> render_click()
    refute render(view) =~ "ticket-detail-modal"

    view |> element(~s(button[phx-click="open-add-agent"])) |> render_click()
    add_agent = render(view)

    # Prefilled from the routing table plus the ticket's own complexity tag. The
    # model select opens on the model the dispatcher would resolve — the value the
    # Tickets table used to print in a "Would route to" column. The expectation is
    # read from the preview rather than hard-coded because the routing table is
    # operator configuration and differs between environments.
    routing = AgentRoutingPreview.preview(["complexity:5"])

    assert routing.resolved_model in AgentRoutingPreview.options(routing.backend).models,
           "the routed model has to be one the modal can offer, or there is nothing to preselect"

    assert add_agent =~ "add-agent-modal"
    assert add_agent =~ "complexity:5"
    assert selected_option(add_agent, "backend") == routing.backend
    assert selected_option(add_agent, "model") == routing.resolved_model
    assert selected_option(add_agent, "complexity") == "5"

    # The routing explainer was deleted; the prefilling behaviour it described stays.
    # The column is refuted by its cell class, not by its header text: the ticket
    # detail modal still renders "Would route to" as a fact, and that is correct.
    refute add_agent =~ "Prefilled from the current routing configuration"
    refute add_agent =~ "tk-agent-cell"

    # Change the prefilled complexity before confirming, as an operator would.
    view |> element(~s(#add-agent-modal form)) |> render_change(%{"complexity" => "3"})
    view |> element(~s(#add-agent-modal form)) |> render_submit(%{})

    # The active-state label is what makes the ticket dispatchable at all, and the
    # complexity tag it replaces is removed rather than left to outrank it. The
    # model label carries the prefilled model, so the value the operator was shown
    # is the value written to the tracker rather than one re-derived later.
    model_label = "model:#{routing.backend}-#{routing.resolved_model}"

    assert_received {:add_label, "2101", "agent:todo"}
    assert_received {:add_label, "2101", "complexity:3"}
    assert_received {:add_label, "2101", ^model_label}
    assert_received {:remove_label, "2101", "complexity:5"}
    assert_received {:dashboard_refresh_requested, ^orchestrator}
    assert render(view) =~ "Applied"
  end

  test "the Tickets panel reveals the next batch on request and retires the control when exhausted" do
    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsRevealOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    # Enough tickets that exhausting the panel takes more than one reveal, so
    # the assign is shown to accumulate rather than jump straight to the end.
    tickets = Enum.map(1..20, &open_ticket("21#{String.pad_leading(to_string(&1), 2, "0")}", []))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot(tickets) end
    )

    {:ok, view, html} = live(build_conn(), "/")

    # The header keeps the total; the control names only the step it reveals.
    assert html =~ "20 tickets"
    assert ticket_row_count(html) == 5
    assert html =~ "Show 10 more tickets"

    revealed = reveal_more_tickets(view)

    # Progressive reveal: the first five stay put and the next batch joins them.
    assert ticket_row_count(revealed) == 15
    assert revealed =~ "Show 5 more tickets"

    exhausted = reveal_more_tickets(view)

    assert ticket_row_count(exhausted) == 20
    refute exhausted =~ "show-more-tickets"
  end

  # A pinned tag expires with its version. When the routing table names a family
  # alias the modal has to open on the alias, not on the concrete version it happens
  # to resolve to today, or confirming strands the ticket on that version while every
  # untouched ticket follows the alias forward.
  test "the add-agent modal opens on a routed family alias rather than the version it resolves to" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), agent_routing: %{3 => "codex:sol"})

    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsAliasOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: true,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot([open_ticket("2103", ["complexity:3"])]) end
    )

    {:ok, view, _html} = live(build_conn(), "/")

    routing = AgentRoutingPreview.preview(["complexity:3"])
    assert routing.model == "sol"
    assert routing.resolved_model != "sol", "only meaningful while `sol` resolves to a concrete version"

    view |> element(~s(button[phx-click="open-add-agent"])) |> render_click()

    assert selected_option(render(view), "model") == "sol"
  end

  test "the Tickets panel search filters the whole backlog and clears back to it" do
    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsSearchOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    tickets = [
      open_ticket("2101", []),
      open_ticket("2102", [],
        title: "Retry the dispatch",
        body_excerpt: "A storm of webhooks overwhelms the poller."
      ),
      open_ticket("2103", [], title: "Documentation refresh")
    ]

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot(tickets) end
    )

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "3 tickets"

    # One term from the title and one from the body, in the other order: the
    # filter is tokenised, not a substring test against a single field.
    filtered = view |> element("form.tk-search") |> render_change(%{"query" => "storm retry"})

    assert filtered =~ "Retry the dispatch"
    refute filtered =~ "Documentation refresh"
    assert filtered =~ "1 of 3 tickets"

    empty = view |> element("form.tk-search") |> render_change(%{"query" => "zzzzqqqq"})

    assert empty =~ "No tickets match"
    refute empty =~ "tickets-rows"

    restored = view |> element("button.tk-search-clear") |> render_click()

    assert restored =~ "Documentation refresh"
    assert restored =~ ~s(<span class="rs-group-count">3 tickets</span>)
  end

  # The two features have to compose: a filter that only saw the revealed batch
  # would report a ticket as absent when it is merely still hidden, and a reveal
  # control counting the whole backlog would offer to reveal rows the query
  # excluded.
  test "the Tickets panel search reaches unrevealed tickets and the reveal control counts the matches" do
    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsSearchRevealOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    # Newest first, so #2101 sorts last — well past the opening batch of five.
    tickets =
      Enum.map(2..20, &open_ticket("21#{String.pad_leading(to_string(&1), 2, "0")}", [])) ++
        [open_ticket("2101", [], title: "Retry the dispatch")]

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> open_ticket_snapshot(tickets) end
    )

    {:ok, view, html} = live(build_conn(), "/")

    assert ticket_row_count(html) == 5
    refute html =~ "Retry the dispatch"

    filtered = view |> element("form.tk-search") |> render_change(%{"query" => "retry"})

    # Found although it was never rendered, and the reveal control is gone
    # because one match does not fill the opening batch.
    assert filtered =~ "Retry the dispatch"
    assert ticket_row_count(filtered) == 1
    assert filtered =~ "1 of 20 tickets"
    refute filtered =~ "show-more-tickets"

    # A broad query keeps the control, and it counts what the query matched —
    # the 19 default titles, not the 20 tickets behind them.
    broad = view |> element("form.tk-search") |> render_change(%{"query" => "backlog"})

    assert ticket_row_count(broad) == 5
    assert broad =~ "Show 10 more tickets"
    assert broad =~ "19 of 20 tickets"
  end

  test "an unavailable ticket listing is named rather than shown as zero tickets" do
    identity = units_identity()
    orchestrator_name = Module.concat(__MODULE__, :TicketsUnavailableOrchestrator)
    orchestrator = start_counting_orchestrator(orchestrator_name)

    replace_counting_snapshot(orchestrator, units_orchestrator_snapshot(identity))

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      units_membership_fun: fn -> units_membership(identity) end,
      units_activity_fun: fn -> units_activity(identity) end,
      open_tickets_fun: fn -> raise "tracker unavailable" end
    )

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Open tickets are unavailable."
    assert html =~ "tickets unavailable"
    refute html =~ "0 tickets"
  end

  defp reveal_more_tickets(view) do
    view |> element(~s(button[phx-click="show-more-tickets"])) |> render_click()
  end

  defp ticket_row_count(html) do
    html |> Floki.parse_document!() |> Floki.find("#tickets-rows tr.tickets-row") |> length()
  end

  # The value of the `selected` option of one named select. Blank comes back as
  # `nil` so it compares against an absent routing value rather than `""`.
  defp selected_option(html, name) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(~s(select[name="#{name}"] option[selected]))
    |> Floki.attribute("value")
    |> List.first()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp open_ticket_snapshot(tickets) do
    %OpenTicketSnapshot{
      status: :available,
      generation: 1,
      observed_at: ~U[2026-07-17 12:00:00Z],
      tickets: tickets
    }
  end

  defp open_ticket(identifier, labels, overrides \\ %{}) do
    Map.merge(
      %{
        identity: units_identity(provider_id: "NODE-#{identifier}", database_id: nil, identifier: identifier),
        identifier: identifier,
        title: "Unrouted backlog ticket",
        body_excerpt: nil,
        url: "https://github.com/its-everdred/aiur/issues/#{identifier}",
        state: "Todo",
        labels: labels,
        assignee: nil,
        created_at: ~U[2026-07-16 12:00:00Z],
        updated_at: ~U[2026-07-17 11:00:00Z]
      },
      Map.new(overrides)
    )
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

  defp start_unit_control(name, opts) do
    identity = units_identity()
    membership = units_membership(identity)
    orchestrator_name = Module.concat(__MODULE__, name)
    orchestrator = start_counting_orchestrator(orchestrator_name)
    test_pid = self()

    snapshot = unit_control_snapshot(identity, Keyword.get(opts, :work_state, :working))
    replace_counting_snapshot(orchestrator, snapshot)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 100,
      control_center_cache: false,
      dashboard_writable: Keyword.get(opts, :writable, true),
      units_membership_fun: fn -> membership end,
      units_activity_fun: fn -> units_activity(identity) end,
      agent_chat_capabilities_fun: fn id ->
        send(test_pid, {:unit_caps, id})
        Keyword.fetch!(opts, :capabilities).()
      end,
      agent_chat_pause_fun: fn id ->
        send(test_pid, {:unit_pause, id})
        Keyword.get(opts, :pause, {:ok, 8})
      end,
      agent_chat_resume_fun: fn id ->
        send(test_pid, {:unit_resume, id})
        Keyword.get(opts, :resume, {:ok, :resumed})
      end
    )

    {:ok, view, html} = live(build_conn(), "/")
    token = UnitsPresenter.row_token(%{identity: identity})
    %{view: view, token: token, html: html, identity: identity}
  end

  defp unit_control_snapshot(identity, work_state) do
    snapshot = units_orchestrator_snapshot(identity)

    running =
      snapshot.running
      |> hd()
      |> Map.put(:work_state, work_state)
      |> Map.put(:tracker_paused, work_state == :paused)

    %{snapshot | running: [running]}
  end

  defp control_status(view, token) do
    socket = :sys.get_state(view.pid).socket

    case socket.assigns.unit_controls[token] do
      nil -> nil
      control -> control.status
    end
  end

  defp lifecycle(action, status, request_id, rejection \\ nil) do
    %{
      action: action,
      status: status,
      request_id: request_id,
      rejection: rejection,
      tracker_identity: %{identifier: "1110"},
      issue_id: "issue-1110",
      generation: 1
    }
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

  # Dashboard routes are behind the FinancialDataAccess plug, which challenges
  # any request once credentials are configured (regardless of `dashboard_auth_required`).
  # test_helper configures credentials globally, so every dashboard render test must
  # present them. Tests that deliberately exercise the unauthenticated or
  # missing-configuration path build their own conn via `Phoenix.ConnTest.build_conn/0`.
  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header(
      "authorization",
      "Basic " <> Base.encode64("operator:test-dashboard-secret")
    )
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

  defp replace_counting_snapshot(orchestrator, snapshot) do
    :sys.replace_state(orchestrator, &Map.put(&1, :snapshot, snapshot))
    {:registered_name, name} = Process.info(orchestrator, :registered_name)
    :ok = SnapshotStore.publish(name, snapshot)
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
      stop_registered_metrics(name)
      File.rm_rf!(dir)
    end)

    {metrics, restart}
  end

  # This helper exists for tests that deliberately replace the same-name
  # DecisionMetrics process, so the pid resolved by whereis/1 can already be
  # terminating by the time stop/1 runs. The desired end state — no process
  # registered under this name — is what the teardown wants, so an exit here is
  # success, not a failure of the test that already passed its assertions.
  defp stop_registered_metrics(name) do
    case GenServer.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  catch
    :exit, _reason -> :ok
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
      state_dir: dir,
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
    # Blocking by default, but a fixture that only needs historic rows must be
    # able to opt out: the store refuses to dismiss a blocking Command it
    # cannot release.
    {blocking?, opts} = Keyword.pop(opts, :blocking, true)

    request =
      %{
        "source_id" => source_id,
        "question" => "Should the dashboard ship this change?",
        "blocking" => blocking?,
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

    assert CountingOrchestrator.snapshot_count(orchestrator) == baseline_count
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

  defp await_dispatched_revision(store, decision_id) do
    assert eventually(
             fn -> match?({:ok, %{revision_result: :dispatched}}, DecisionStore.get(decision_id, store)) end,
             200
           ),
           "the store never recorded the revision dispatch: #{inspect(DecisionStore.get(decision_id, store))}"

    DecisionStore.get(decision_id, store)
  end

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
