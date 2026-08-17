defmodule AiurWeb.OperatorControlCenter.UnitsTableTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

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
    refute html =~ ~s(href="/commands?ticket=1110")
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
    assert html =~ ~s(class="ut-pbar is-unknown")
    refute html =~ ~s(class="ut-progress-fill")
  end

  test "marks measured zero, completion, and stale progress without semantic recoloring" do
    plain = row() |> update_in([:reasons], &%{&1 | blocking: nil, alert: nil}) |> put_in([:progress, :freshness], :current)
    zero = render(view([put_in(plain, [:progress, :percent], 0)]))
    complete = render(view([put_in(plain, [:progress, :percent], 100)]))
    stale = render(view([put_in(plain, [:progress, :freshness], :stale)]))

    blocked_complete =
      row()
      |> put_in([:progress, :percent], 100)
      |> put_in([:progress, :freshness], :current)
      |> put_in([:reasons, :blocking], :dependency)
      |> then(&render(view([&1])))

    assert zero =~ ~s(class="ut-progress-fill")
    assert zero =~ "width:0%"
    refute zero =~ "is-unknown"
    assert complete =~ ~s(class="ut-progress-fill is-complete")
    assert stale =~ ~s(class="ut-progress-fill is-stale")
    assert blocked_complete =~ ~s(class="ut-progress-fill is-complete")
    refute blocked_complete =~ ~s(class="ut-progress-fill is-complete is-blocked")
  end

  test "resolves string-backed registry families and backends" do
    row = row() |> Map.put(:agent_family, "fake") |> Map.put(:backend, "fake")

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    assert html =~ ~s(class="u-pill u-agent is-fake")
    assert html =~ ">Fake</span>"
    assert html =~ "--provider-unit-color"
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
    # The placeholder is not a unit: `#units-rows` stays empty so every row
    # selector keyed on it still counts only real units.
    refute unavailable =~ ~r{<tbody id="units-rows">\s*<tr}
    assert unavailable =~ "Units catalog unavailable"
    assert unavailable =~ "membership failed"
    # Every zero-unit catalog reads the same sentence. The per-status detail is
    # not lost: `UnitsPresenter.announcement/1` derives its own copy from the
    # status, so the box no longer needs to paint `@message` as well.
    assert empty =~ "No live units."
    refute empty =~ "No units observed"
    assert filtered =~ "No units match this valid scope"
    assert filtered =~ ~s(phx-click="reset-units-filters")
    assert filtered =~ ~s(class="btn ghost units-reset")
    # A stale catalog no longer prints a dedicated banner; the last-known-good
    # rows render directly without the noisy "Stale Units catalog" notice.
    refute stale =~ "Stale Units catalog"
    refute stale =~ "last known membership"
    assert stale =~ "units-table"
    assert stale =~ "Responsive Units interface"

    # A stale catalog with nothing retained must still account for the empty
    # table rather than rendering a blank area. It keeps the column headings so
    # the catalog reads as empty rather than absent, and it still says why it is
    # empty instead of claiming a fleet-wide emptiness it never observed.
    stale_empty = render(%{status: :stale, message: "No last-known-good Units catalog is retained.", rows: [], zero_result?: false})
    refute stale_empty =~ "Stale Units catalog"
    assert stale_empty =~ "No last-known-good Units catalog is retained."
    refute stale_empty =~ "No live units."
    assert stale_empty =~ "units-table"

    # With no reason composed, the ordinary empty-state sentence still stands in.
    stale_empty_unexplained = render(%{status: :stale, message: nil, rows: [], zero_result?: false})
    assert stale_empty_unexplained =~ "No live units."

    # The filter-hides-everything case still belongs to zero_result?, not to the
    # catalog-empty message.
    stale_filtered = render(%{status: :stale, message: "last known membership", rows: [], zero_result?: true})
    assert stale_filtered =~ "No units match this valid scope"
    refute stale_filtered =~ "No live units."

    partial = render(Map.merge(view([row()]), %{truncated?: true, count_status: :partial}))
    assert partial =~ "Units catalog is partial"
    assert partial =~ "Counts are lower bounds"
  end

  test "keeps the column headings and names the empty state when the catalog holds no units" do
    html = render(%{status: :empty, message: "No units observed", rows: [], zero_result?: false})

    # The headings are the table's shape: they stay put at zero units so the
    # operator reads an empty catalog rather than a vanished one.
    assert html =~ ~s(<thead>)
    assert html =~ ~s(<th class="ut-col-id">ID</th>)
    assert html =~ ~s(<th class="ut-col-unit">Unit</th>)
    assert html =~ ~s(<th class="ut-col-ticket">Ticket</th>)
    assert html =~ ~s(<th class="ut-col-latest">Latest</th>)
    assert html =~ ~s(<th class="ut-col-cmd">Command</th>)

    # The empty state sits below the table in the dashboard's shared
    # dashed-border `empty-state` surface.
    assert html =~ ~s(class="units-state empty-state")
    assert html =~ "No live units."
  end

  test "withholds the zero-unit sentence from the statuses that already account for themselves" do
    # `:loading` has not finished answering the question yet, and `:unavailable`
    # names its own fault twice over — a banner and an in-table row. Either one
    # would read as a contradiction beside "No live units.", so the guard in
    # `no_units?/3` excludes them and this pins both sides of that exclusion.
    loading = render(%{status: :loading, message: nil, rows: [], zero_result?: false})
    assert loading =~ "Loading Units"
    refute loading =~ "No live units."

    unavailable = render(%{status: :unavailable, message: "membership failed", rows: [], zero_result?: false})
    assert unavailable =~ "No active agents"
    refute unavailable =~ "No live units."
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

  test "reserves the red alert treatment for rows blocked awaiting a command/decision" do
    html = render(view([row_with_tone(:blocked)]))

    assert html =~ ~s(class="units-row is-blocked")
    refute html =~ ~s(class="ut-alert")
  end

  test "paused and queued rows never render red even with blocking/alert reasons" do
    paused = render(view([row_with_tone(:paused_with_attention)]))
    queued = render(view([row_with_tone(:queued_with_attention)]))

    assert paused =~ ~s(class="units-row is-paused")
    refute paused =~ ~s(class="units-row is-blocked")
    refute paused =~ ~s(class="units-row has-alert")

    assert queued =~ ~s(class="units-row is-queued")
    refute queued =~ ~s(class="units-row is-blocked")
    refute queued =~ ~s(class="units-row has-alert")
  end

  test "renders active, queued, and paused rows with distinct non-red tones" do
    active = render(view([row_with_tone(:active)]))
    queued = render(view([row_with_tone(:queued)]))
    paused = render(view([row_with_tone(:paused)]))

    # Active is neutral: no tone class and no warning glyph.
    refute active =~ ~s(is-blocked)
    refute active =~ ~s(is-paused)
    refute active =~ ~s(is-queued)
    refute active =~ ~s(has-alert)
    refute active =~ ~s(class="ut-alert")

    # Queued is muted and never carries the red-blocking or warning treatment.
    assert queued =~ ~s(class="units-row is-queued")
    refute queued =~ ~s(is-blocked)
    refute queued =~ ~s(class="ut-alert")

    # Paused is a subtle amber/gray tone, distinct from blocked red.
    assert paused =~ ~s(class="units-row is-paused")
    refute paused =~ ~s(is-blocked)
    refute paused =~ ~s(class="ut-alert")
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

  defp row_with_tone(:blocked), do: row()

  defp row_with_tone(:active) do
    row()
    |> Map.put(:reasons, %{waiting: :active, blocking: nil, alert: nil, pause: nil, stuck: nil})
    |> Map.put(:open_command_count, 0)
    |> put_in([:runtime, :waiting_reason], :active)
    |> put_in([:runtime, :work_state], :working)
  end

  defp row_with_tone(:queued) do
    row()
    |> Map.put(:reasons, %{waiting: :awaiting_dispatch, blocking: nil, alert: nil, pause: nil, stuck: nil})
    |> Map.put(:open_command_count, 0)
    |> put_in([:runtime, :bucket], :retrying)
    |> put_in([:runtime, :waiting_reason], :awaiting_dispatch)
    |> put_in([:runtime, :work_state], :idle)
  end

  defp row_with_tone(:paused) do
    row()
    |> Map.put(:reasons, %{waiting: :paused, blocking: nil, alert: nil, pause: :operator_pause, stuck: nil})
    |> Map.put(:open_command_count, 0)
    |> put_in([:runtime, :work_state], :paused)
    |> put_in([:runtime, :waiting_reason], :paused)
  end

  defp row_with_tone(:paused_with_attention) do
    row() |> put_in([:runtime, :work_state], :paused)
  end

  defp row_with_tone(:queued_with_attention) do
    row()
    |> Map.put(:reasons, %{waiting: :awaiting_dispatch, blocking: :waiting_for_dependency, alert: :open_command, pause: nil, stuck: nil})
    |> put_in([:runtime, :bucket], :retrying)
    |> put_in([:runtime, :waiting_reason], :awaiting_dispatch)
    |> put_in([:runtime, :work_state], :idle)
  end
end
