defmodule AiurWeb.OperatorControlCenter.UnitsTableTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.{UnitsPresenter, UnitsTable}

  import AiurWeb.OperatorControlCenter.UnitsTableFixtures

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
    assert html =~ "Turns 3"
    assert html =~ "Context 50% 50k/100k"
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
        turn_count: nil,
        context_usage: nil,
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
    assert html =~ "Turns no attempt"
    assert html =~ "Context no attempt"
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

  test "keeps a known zero turn count and unknown context capacity distinct" do
    row = %{row() | turn_count: 0, context_usage: %{used_tokens: 50_000}}

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    assert html =~ "Turns 0"
    assert html =~ "Context 50k/? ctx"
  end

  test "a running unit without turn or context measurements says not reported and why" do
    row = %{row() | turn_count: nil, context_usage: nil, backend: "claude"}

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    assert html =~ ~s(title="The claude backend has not reported a turn count for this attempt">Turns not reported<)
    assert html =~ ~s(title="The claude backend has not reported context occupancy for this attempt">Context not reported<)
    refute html =~ "Turns —"
    refute html =~ "Context —"
    refute html =~ "Turns 0"
    refute html =~ ~r/Context 0[^%]/
  end

  test "marks measured zero and completion without semantic recoloring" do
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
    refute stale =~ "is-stale"
    assert blocked_complete =~ ~s(class="ut-progress-fill is-complete")
    refute blocked_complete =~ ~s(class="ut-progress-fill is-complete is-blocked")
  end

  test "names the model and version beside the backend, titled with the raw id" do
    # The provider chip says which vendor is running the ticket; an operator
    # comparing two units also needs to know which model of that vendor, and
    # the exact id has to stay recoverable for a bug report.
    row = row() |> Map.put(:requested_model, "opus") |> Map.put(:resolved_model, "claude-opus-5-1")

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    assert html =~ ~s(class="u-pill u-model" title="claude-opus-5-1">OPUS 5.1</span>)
  end

  test "omits the model chip entirely when no source names a model" do
    row = row() |> Map.merge(%{backend: nil, agent_family: :codex, requested_model: nil, resolved_model: nil})

    html =
      render_component(&UnitsTable.units_table/1, %{
        view: view([row]),
        now: ~U[2026-07-17 12:00:00Z]
      })

    refute html =~ ~s(class="u-pill u-model")
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
    # (column headings + a single "No active units" row) rather than an error.
    assert unavailable =~ "No active units"
    assert unavailable =~ "units-table"
    # The placeholder is not a unit: `#units-rows` stays empty so every row
    # selector keyed on it still counts only real units.
    refute unavailable =~ ~r{<tbody id="units-rows">\s*<tr}
    assert unavailable =~ "No live units"
    assert unavailable =~ "membership failed"
    # Every zero-unit catalog reads the same sentence. The per-status detail is
    # not lost: `UnitsPresenter.announcement/1` derives its own copy from the
    # status, so the box no longer needs to paint `@message` as well.
    assert empty =~ "No live units."
    refute empty =~ "No units observed"
    assert filtered =~ "No units match this valid scope"
    assert filtered =~ ~s(phx-click="reset-units-filters")
    assert filtered =~ ~s(class="aiur-button aiur-button--dashboard aiur-button--ghost btn ghost units-reset")
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
    stale_empty = render(%{status: :stale, message: "No live units. Fleet data is unavailable.", rows: [], zero_result?: false})
    refute stale_empty =~ "Stale Units catalog"
    assert stale_empty =~ "No live units. Fleet data is unavailable."
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
    assert partial =~ "Partial list"
    assert partial =~ "Counts are at least this high"
  end

  test "keeps the column headings and names the empty state when the catalog holds no units" do
    html = render(%{status: :empty, message: "No units observed", rows: [], zero_result?: false})

    # The headings are the table's shape: they stay put at zero units so the
    # operator reads an empty catalog rather than a vanished one.
    assert html =~ ~s(<thead>)
    assert html =~ ~s(<th class="ut-col-id" data-sort-key="id" data-sort-type="number">ID</th>)
    assert html =~ ~s(<th class="ut-col-unit" data-sort-key="unit">Unit</th>)
    assert html =~ ~s(<th class="ut-col-ticket" data-sort-key="ticket">Ticket</th>)
    assert html =~ ~s(<th class="ut-col-latest" data-sort-key="latest" data-sort-type="number">Latest</th>)

    # The Command column holds actions, so it carries no sort affordance.
    assert html =~ ~s(<th class="ut-col-cmd">Command</th>)

    # The empty state sits below the table in the dashboard's shared
    # dashed-border `empty-state` surface.
    assert html =~ ~s(class="units-state empty-state")
    assert html =~ "No live units."
  end

  test "marks a usage-limit pause as not holding a fleet slot, and only that pause" do
    limited = Map.put(row_with_tone(:paused), :reasons, %{waiting: :provider_limited, blocking: nil, alert: nil, pause: :usage_limit_exhausted, stuck: nil})
    render = fn row -> render_component(&UnitsTable.units_table/1, %{view: view([row]), now: ~U[2026-07-17 12:00:00Z]}) end

    assert render.(limited) =~ "Slot released"
    refute render.(row_with_tone(:paused)) =~ "Slot released"
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
    assert unavailable =~ "No active units"
    refute unavailable =~ ~s(units-empty-cell" colspan="5">No live units.)
  end
end
