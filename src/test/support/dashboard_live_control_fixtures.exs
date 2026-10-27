defmodule AiurWeb.DashboardLiveSupport.ControlFixtures do
  @moduledoc false

  import ExUnit.Callbacks, only: [start_supervised!: 2]
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import AiurWeb.DashboardLiveSupport, only: [build_conn: 0, start_test_endpoint: 1]
  import AiurWeb.DashboardLiveSupport.UnitFixtures, only: [units_identity: 0, units_membership: 1, units_activity: 1, units_orchestrator_snapshot: 1]
  import AiurWeb.DashboardLiveSupport.Processes, only: [start_counting_orchestrator: 1, replace_counting_snapshot: 2]

  alias Aiur.TrackerIdentity
  alias AiurWeb.DashboardLiveSupport.OrchestratorStubs.CountingOrchestrator
  alias AiurWeb.OperatorControlCenter.UnitsPresenter

  @endpoint AiurWeb.Endpoint

  def start_unit_control(name, opts) do
    identity = units_identity()
    membership = units_membership(identity)
    orchestrator_name = Module.concat(AiurWeb.DashboardLiveTest, name)
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

    {:ok, view, html} = live(build_conn(), "/units")
    token = UnitsPresenter.row_token(%{identity: identity})
    %{view: view, token: token, html: html, identity: identity}
  end

  def unit_control_snapshot(identity, work_state) do
    snapshot = units_orchestrator_snapshot(identity)

    running =
      snapshot.running
      |> hd()
      |> Map.put(:work_state, work_state)
      |> Map.put(:tracker_paused, work_state == :paused)

    %{snapshot | running: [running]}
  end

  def control_status(view, token) do
    socket = :sys.get_state(view.pid).socket

    case socket.assigns.unit_controls[token] do
      nil -> nil
      control -> control.status
    end
  end

  def lifecycle(action, status, request_id, rejection \\ nil) do
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

  def start_outcomes_dashboard do
    test_process = self()

    start_outcomes_dashboard(fn destination, message, delay_ms ->
      send(test_process, {:outcomes_flush_scheduled, destination, message, delay_ms})
      make_ref()
    end)
  end

  def start_outcomes_dashboard(flush_timer) when is_function(flush_timer, 3) do
    orchestrator_name = Module.concat(AiurWeb.DashboardLiveTest, :OutcomesOrchestrator)

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

    {:ok, view, _html} = live(build_conn(), "/units")
    view
  end

  # Deterministically apply one pushed outcome snapshot: process the update
  # (which schedules but defers the coalesced flush), then run the flush.
  def push_outcomes(view, snapshot) do
    send(view.pid, {:current_run_outcome_snapshot_changed, snapshot})
    :sys.get_state(view.pid)
    send(view.pid, :flush_current_run_outcomes)
    render(view)
  end

  def healthy_outcomes_snapshot(opts) do
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

  def outcome_fixture(number) do
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
end
