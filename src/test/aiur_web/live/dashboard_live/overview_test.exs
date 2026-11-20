defmodule AiurWeb.DashboardLive.OverviewTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport
  import AiurWeb.DashboardLiveSupport.DecisionFixtures

  alias Aiur.Orchestrator.SnapshotStore
  alias AiurWeb.ControlCenterPresenter
  alias AiurWeb.OperatorControlCenter.Overview
  alias AiurWeb.OperatorControlCenter.PayloadLoader

  @endpoint AiurWeb.Endpoint

  test "dashboard payload uses the endpoint startup clock" do
    orchestrator_name = {:global, make_ref()}
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      SnapshotStore.forget(orchestrator_name)
    end)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 5,
      control_center_cache: false,
      units_startup_elapsed_ms_fun: fn -> 600_000 end
    )

    assert %{units: %{status: :unavailable}} = PayloadLoader.load(:fresh)
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

  test "renders Commands navigation without retired destinations" do
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
    assert [_] = Floki.find(Floki.parse_document!(unavailable_units), ~s(a[href="/commands"][aria-current="page"]))
    assert Floki.parse_document!(unavailable_units) |> Floki.find("#route-title") |> Floki.text() =~ "Commands"
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

    assert inbox_html =~ ~s(src="/aiur-style/assets/aiur-logo.png")
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
        needs_you: 73,
        needs_you_blocking: 4,
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

    assert html =~ "73 Commands need you"
    assert html =~ "Issue commands"
    assert html =~ "Partial Command counts"
    assert html =~ "Partial Command data"
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
