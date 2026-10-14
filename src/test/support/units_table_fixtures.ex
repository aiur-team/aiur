defmodule AiurWeb.OperatorControlCenter.UnitsTableFixtures do
  @moduledoc false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.UnitsTable

  def render_controls(rows, controls, writable) do
    render_component(&UnitsTable.units_table/1, %{
      view: view(rows),
      now: ~U[2026-07-17 12:00:00Z],
      controls: controls,
      writable: writable
    })
  end

  def render(view) do
    render_component(&UnitsTable.units_table/1, %{view: view, now: ~U[2026-07-17 12:00:00Z]})
  end

  def view(rows) do
    %{status: :ready, message: nil, rows: rows, zero_result?: false}
  end

  def row do
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
      account: nil,
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
      turn_count: 3,
      context_usage: %{used_tokens: 50_000, window_tokens: 100_000},
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

  def row_with_tone(:blocked), do: row()

  def row_with_tone(:active) do
    row()
    |> Map.put(:reasons, %{waiting: :active, blocking: nil, alert: nil, pause: nil, stuck: nil})
    |> Map.put(:open_command_count, 0)
    |> put_in([:runtime, :waiting_reason], :active)
    |> put_in([:runtime, :work_state], :working)
  end

  def row_with_tone(:queued) do
    row()
    |> Map.put(:reasons, %{waiting: :awaiting_dispatch, blocking: nil, alert: nil, pause: nil, stuck: nil})
    |> Map.put(:open_command_count, 0)
    |> put_in([:runtime, :bucket], :retrying)
    |> put_in([:runtime, :waiting_reason], :awaiting_dispatch)
    |> put_in([:runtime, :work_state], :idle)
  end

  def row_with_tone(:paused) do
    row()
    |> Map.put(:reasons, %{waiting: :paused, blocking: nil, alert: nil, pause: :operator_pause, stuck: nil})
    |> Map.put(:open_command_count, 0)
    |> put_in([:runtime, :work_state], :paused)
    |> put_in([:runtime, :waiting_reason], :paused)
  end

  def row_with_tone(:paused_with_attention) do
    row() |> put_in([:runtime, :work_state], :paused)
  end

  def row_with_tone(:queued_with_attention) do
    row()
    |> Map.put(:reasons, %{waiting: :awaiting_dispatch, blocking: :waiting_for_dependency, alert: :open_command, pause: nil, stuck: nil})
    |> put_in([:runtime, :bucket], :retrying)
    |> put_in([:runtime, :waiting_reason], :awaiting_dispatch)
    |> put_in([:runtime, :work_state], :idle)
  end
end
