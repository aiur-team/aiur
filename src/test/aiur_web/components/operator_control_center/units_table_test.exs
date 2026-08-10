defmodule AiurWeb.OperatorControlCenter.UnitsTableTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.CodingAgent
  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.{UnitsPresenter, UnitsTable}

  test "renders normalized facts, determinate progress, and only named actions" do
    row = row()
    token = UnitsPresenter.row_token(row)

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    assert html =~ ~s(id="unit-#{token}")
    # The row cells are the inspect trigger; the command column keeps only compact actions.
    assert html =~ ~s(phx-click="inspect-unit")
    assert html =~ ~s(class="ut-id-cell ut-open")
    assert html =~ "data-ticket-context-origin"
    assert html =~ "acme/aiur #1110"
    assert html =~ "Responsive Units interface"
    assert html =~ ~s(class="u-lane is-lane-L2")
    assert html =~ "gpt-5.6"
    assert html =~ ~s(class="u-pill u-agent is-codex")
    assert html =~ ~s(class="u-pill u-prio)
    assert html =~ ~s(class="ut-pbar")
    assert html =~ "width:40%"
    assert html =~ "feature pushed"
    refute html =~ "Conversation unavailable"
    refute html =~ ~s(phx-click="read-conversation")
    # Verbose per-row Commands / GitHub / Agent-log actions moved into the inspect modal.
    refute html =~ "Inspect ticket"
    refute html =~ ~s(href="/decisions?ticket=1110")
    refute html =~ ">Agent log</button>"
    # The standalone read-agent-log row action is gone: the chat modal now
    # carries the agent log beneath the conversation.
    refute html =~ "Read agent log"
    refute html =~ ~s(phx-click="show-agent-log")
    assert html =~ ~s(phx-value-unit="#{token}")
    refute html =~ ~s(phx-value-issue="1110")
    refute html =~ ~r/<tr[^>]+phx-click=/
  end

  test "labels unknown values without fabricating progress, models, or unsafe links" do
    row =
      row()
      |> Map.merge(%{
        url: "https://example.com/private",
        requested_model: nil,
        resolved_model: nil,
        effort: nil,
        complexity: nil,
        build_lane: nil,
        progress: %{status: :unknown},
        latest_evidence: %{status: :unknown},
        open_command_count: nil,
        provider_health: %{membership: :available, status: :unavailable, activity: :unknown}
      })
      |> put_in([:runtime, :bucket], :idle)
      |> Map.put(:workspace_path, "/private/workspace")

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    assert html =~ "No recent activity"
    # Unknown progress facts are omitted rather than labelled "Unavailable"/"Unknown".
    refute html =~ "Progress source"
    refute html =~ "Latest evidence"
    assert html =~ ~s(class="u-pill u-agent)
    assert html =~ ~s(class="u-pill u-prio)
    refute html =~ "aria-valuenow"
    refute html =~ ~s(<span>0%</span>)
    refute html =~ "github.com/acme/aiur/issues/1110"
    refute html =~ "example.com"
    refute html =~ "/private/workspace"
    refute html =~ "Agent log"
  end

  test "resolves string-backed registry families and backends" do
    row = row() |> Map.put(:agent_family, "fake") |> Map.put(:backend, "fake")

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    assert html =~ ~s(class="u-pill u-agent is-fake")
    assert html =~ "--provider-unit-color"

    # The pill shows the registry's mark, not the provider's name. The name
    # survives as the image's accessible name rather than as a text node.
    assert html =~ ~s(class="u-agent-logo")
    assert html =~ ~s(alt="Fake")
    refute html =~ ">Fake</span>"
  end

  test "renders the provider mark from the registry descriptor" do
    row = row() |> Map.put(:agent_family, "fake") |> Map.put(:backend, "fake")

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    %{logo: logo, label: label} = CodingAgent.provider_descriptor(:fake)

    # Asserted against the descriptor rather than a literal path, so a registry
    # change moves the test with it instead of silently diverging.
    assert html =~ ~s(src="#{logo}")
    assert html =~ ~s(alt="#{label}")
  end

  test "falls back to the provider name when the family resolves no descriptor" do
    row = row() |> Map.put(:agent_family, "not-a-registered-backend") |> Map.put(:backend, nil)

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    # An unknown family has no logo, so the pill must still name something
    # rather than render empty.
    refute html =~ ~s(class="u-agent-logo")
    assert html =~ ">Agent</span>"
  end

  test "distinguishes unavailable, healthy-empty, filtered-empty, and stale catalog states" do
    unavailable = render(%{status: :unavailable, message: "membership failed", rows: [], zero_result?: false})
    empty = render(%{status: :empty, message: "No units observed", rows: [], zero_result?: false})
    filtered = render(%{status: :ready, message: nil, rows: [], zero_result?: true})
    stale = render(%{view([row()]) | status: :stale, message: "last known membership"})

    # An unavailable current-run membership renders the empty catalog table
    # (column headings + a single "No active agents" row) rather than an error.
    assert unavailable =~ "No active agents"
    assert unavailable =~ "units-table"
    assert empty =~ "No units observed"
    assert filtered =~ "No units match this valid scope"
    assert filtered =~ ~s(phx-click="reset-units-filters")
    assert filtered =~ ~s(class="btn ghost units-reset")
    assert stale =~ "Units may be stale"
    assert stale =~ "last known membership"
    assert stale =~ "Responsive Units interface"

    partial = render(Map.merge(view([row()]), %{truncated?: true, count_status: :partial}))
    assert partial =~ "Units catalog is partial"
    assert partial =~ "Counts are lower bounds"
  end

  test "renders a named, reachable pause control for a running unit when writable" do
    row = row()
    token = UnitsPresenter.row_token(row)
    html = render_controls([row], %{}, true)

    assert html =~ ~s(id="units-control-#{token}")
    assert html =~ ~s(phx-click="request-unit-control")
    assert html =~ ~s(phx-value-unit="#{token}")
    assert html =~ ~s(phx-value-action="pause")
    assert html =~ ~s(aria-label="Pause acme/aiur #1110")
    assert html =~ "units-control-action"
    assert html =~ ~s(title="Pause")
    assert html =~ ~s(aria-disabled="false")
  end

  test "renders resume for an applied-paused unit" do
    row = put_in(row(), [:runtime, :work_state], :paused)
    html = render_controls([row], %{}, true)

    assert html =~ ~s(phx-value-action="resume")
    assert html =~ ~s(title="Resume")
    assert html =~ "is-resume"
  end

  test "disables the control and marks read-only when the dashboard is not writable" do
    row = row()
    html = render_controls([row], %{}, false)

    assert html =~ ~s(disabled)
    assert html =~ ~s(aria-disabled="true")
  end

  test "renders a disabled control with a reason for a terminal unit" do
    row = Map.put(row(), :terminal?, true)
    html = render_controls([row], %{}, true)

    assert html =~ "units-control-disabled"
    assert html =~ "Control unavailable"
    refute html =~ ~s(phx-click="request-unit-control")
  end

  test "mirrors applied evidence only from lifecycle state, with an aria-live status" do
    row = put_in(row(), [:runtime, :work_state], :paused)
    token = UnitsPresenter.row_token(row)
    controls = %{token => %{action: :pause, status: :applied, identifier: "1110"}}
    html = render_controls([row], controls, true)

    assert html =~ "units-control-status"
    assert html =~ ~s(aria-live="polite")
    assert html =~ "tone-applied"
    assert html =~ "Paused"
  end

  test "surfaces a retryable rejection distinctly from success" do
    row = row()
    token = UnitsPresenter.row_token(row)
    controls = %{token => %{action: :pause, status: :rejected, rejection: %{class: :control_failed}, identifier: "1110"}}
    html = render_controls([row], controls, true)

    assert html =~ "tone-error"
    assert html =~ "retry"
    refute html =~ "tone-applied"
  end

  test "request-only never masquerades as an applied control" do
    row = row()
    token = UnitsPresenter.row_token(row)
    controls = %{token => %{action: :pause, status: :request_only, identifier: "1110"}}
    html = render_controls([row], controls, true)

    assert html =~ "tone-warning"
    assert html =~ "request-only"
    refute html =~ "tone-applied"
  end

  defp render_controls(rows, controls, writable) do
    render_component(&UnitsTable.units_table/1, %{
      view: view(rows),
      now: ~U[2026-07-17 12:00:00Z],
      controls: controls,
      writable: writable
    })
  end

  defp render(view) do
    render_component(&UnitsTable.units_table/1, %{view: view, now: ~U[2026-07-17 12:00:00Z]})
  end

  test "offers the explicit Read conversation action only when a valid handle is present" do
    handle = "conversation:" <> String.duplicate("a", 43)
    row = Map.put(row(), :live_conversation, %{generation_handle: handle})
    token = UnitsPresenter.row_token(row)

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    assert html =~ ~s(id="units-conversation-#{token}")
    assert html =~ ~s(phx-click="read-conversation")
    assert html =~ "Open chat for acme/aiur #1110"
    refute html =~ "Conversation unavailable"
    refute html =~ handle
  end

  defp view(rows) do
    %{status: :ready, message: nil, rows: rows, zero_result?: false}
  end

  defp row do
    %{
      identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "acme",
        repository: "aiur",
        provider_id: "NODE-1110",
        database_id: 1110,
        identifier: "1110",
        reason: nil
      },
      title: "Responsive Units interface",
      url: "https://github.com/acme/aiur/issues/1110",
      lifecycle: :active,
      terminal?: false,
      replacement_boundary?: false,
      tracker_state: "in-progress",
      backend: :codex,
      agent_family: :codex,
      requested_model: "gpt-5.6-terra",
      resolved_model: "gpt-5.6",
      effort: :high,
      complexity: 3,
      build_lane: "L2",
      reasons: %{
        waiting: :waiting_for_human,
        blocking: :waiting_for_human,
        alert: :open_command,
        pause: nil,
        stuck: nil
      },
      runtime: %{
        bucket: :running,
        work_state: :working,
        waiting_reason: :waiting_for_human,
        runtime_seconds: 3_900,
        stale_for_seconds: 15,
        tracker_paused?: false,
        membership_lifecycle: :active
      },
      timestamps: %{
        first_observed_at: ~U[2026-07-17 10:00:00Z],
        last_observed_at: ~U[2026-07-17 11:59:00Z],
        started_at: "2026-07-17T10:55:00Z",
        last_activity_at: "2026-07-17T11:59:00Z"
      },
      open_command_count: 2,
      progress: %{status: :known, percent: 40, source: :checkin, freshness: :stale},
      latest_evidence: %{status: :known, source: %{kind: :branch, name: "feature pushed"}},
      provider_health: %{
        membership: :available,
        status: :available,
        activity: :available,
        decisions: :available,
        issue: :available
      },
      field_sources: %{},
      sources: %{}
    }
  end
end
