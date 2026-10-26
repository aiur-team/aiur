defmodule AiurWeb.DashboardLive.OverviewTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures
  import AiurWeb.DashboardLiveSupport.UnitFixtures

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.TestSupport.RefreshTrace
  alias AiurWeb.ControlCenterPresenter
  alias AiurWeb.ObservabilityPubSub
  alias AiurWeb.OperatorControlCenter.Overview
  alias AiurWeb.OperatorControlCenter.UnitsPresenter
  alias AiurWeb.Presenter

  @endpoint AiurWeb.Endpoint

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
    {:ok, view, initial_html} = live(build_conn(), "/units")
    # Before the first fleet view is available, keep counts unknown and label
    # the state as startup loading rather than empty or unavailable.
    assert initial_html =~ "Loading Units…"
    refute Enum.any?(["0+", "Pause state unknown", "snapshot_unpublished", "No fleet data"], &String.contains?(initial_html, &1))

    :ok = ObservabilityPubSub.subscribe()
    :sys.replace_state(pid, &%{&1 | snapshot_ready?: true})
    assert RefreshTrace.count(fn -> :ok = StatusReport.notify_dashboard(:sys.get_state(pid)) end) == 0

    assert eventually(fn -> assert_receive({:observability_updated, _event_id}, 1_000) && match?({:current, _, _}, SnapshotStore.read(orchestrator_name, 1_000)) end)
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

  test "renders document navigation while keeping rollback destinations hidden" do
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

    assert length(Floki.find(Floki.parse_document!(unavailable_units), ~s(nav[aria-label="Views"]))) == 1
    assert Floki.find(Floki.parse_document!(unavailable_units), ~s(a[aria-current="page"])) == []
    assert Floki.parse_document!(unavailable_units) |> Floki.find("#route-title") |> Floki.text() =~ "Units"
    assert unavailable_units =~ ~s(href="/analytics")
    refute unavailable_units =~ ~s(href="/build-orders")
    assert unavailable_units =~ ~s(href="/")
    assert unavailable_units =~ ~s(data-phx-link="redirect")
    # Scope to nav anchors: the global-pause toggle is a button that is
    # legitimately disabled in this read-only render, and is not a nav route.
    assert Floki.find(Floki.parse_document!(unavailable_units), ~s(a[aria-disabled="true"])) == []

    assert available_units =~ ~s(href="/analytics")
    assert Floki.find(Floki.parse_document!(available_units), ~s(a[aria-disabled="true"])) == []

    assert Floki.parse_document!(commands) |> Floki.find("#route-title") |> Floki.text() =~ "Commands"
    assert length(Floki.find(Floki.parse_document!(commands), ~s(a[aria-current="page"]))) == 1
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
      |> Map.put(:decisions, [Map.put(decision, :open?, true)])
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
end
