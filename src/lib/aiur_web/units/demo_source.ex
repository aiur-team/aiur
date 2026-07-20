defmodule AiurWeb.Units.DemoSource do
  @moduledoc """
  STUBBED demo Units source. Feeds the "/" dashboard Units table with rich,
  synthetic agent/unit rows so the catalog renders like the design without a
  live Orchestrator. Gated behind AIUR_UNITS_DEMO in config/config.exs.

  Titles/lanes/complexity are lifted from priv/build_orders/croptracker-demo.json
  (hardcoded here — no runtime file read). Remove this module + the
  AIUR_UNITS_DEMO blocks in config/config.exs and the `:units_fleet_fun` read in
  payload_loader.ex to delete.

  Shapes are dictated by:
    - AiurWeb.ControlCenterPresenter.state_payload/3   (:fleet_fun result)
    - AiurWeb.OperatorControlCenter.UnitsPresenter.load/2 (membership_fun/activity_fun)
    - AiurWeb.OperatorControlCenter.UnitsRow.* projection
    - AiurWeb.OperatorControlCenter.UnitsPolicy condition truth table
  """

  alias Aiur.TrackerIdentity

  @owner "its-everdred"
  @repository "croptracker"
  @generated_at "2026-07-19T17:04:00Z"

  # One spec per unit. `bucket` is the fleet list it lives in (drives runtime.bucket
  # and the Live scope). Every unit contributes: a fleet row (title/lane/model/state),
  # a membership member, and an activity entry — all sharing one identity.
  defp specs do
    [
      # ── ACTIVE (Claude) ────────────────────────────────────────────────
      %{
        number: 104,
        title: "Model canonical PositionSnapshot position tree",
        build_lane: "core",
        complexity: 3,
        agent_family: :claude,
        backend: :claude_code,
        requested_model: "Sonnet 4.6",
        resolved_model: "Sonnet 4.6",
        effort: :standard,
        tracker_state: :in_progress,
        bucket: :running,
        work_state: :working,
        lifecycle: :running,
        terminal?: false,
        runtime_seconds: 2_400,
        percent: 62,
        evidence: {:commit, "a1b2c3d position tree types"}
      },
      # ── ALERT (Codex, open commands) ───────────────────────────────────
      %{
        number: 118,
        title: "Scaffold hosted-api Fastify runtime skeleton",
        build_lane: "platform",
        complexity: 3,
        agent_family: :codex,
        backend: :codex_cli,
        requested_model: "Sol 5.6",
        resolved_model: "Sol 5.6",
        effort: :deep,
        tracker_state: :in_progress,
        bucket: :running,
        work_state: :working,
        lifecycle: :running,
        terminal?: false,
        runtime_seconds: 5_400,
        percent: 78,
        open_decision_count: 3,
        alert_reason: :awaiting_operator_decision,
        evidence: {:pull_request, "#412 hosted-api skeleton"}
      },
      # ── PAUSED (Claude) ────────────────────────────────────────────────
      %{
        number: 112,
        title: "Build log-redaction guard and safe logger factory",
        build_lane: "core",
        complexity: 3,
        agent_family: :claude,
        backend: :claude_code,
        requested_model: "Opus 4.6",
        resolved_model: "Opus 4.6",
        effort: :deep,
        tracker_state: :in_progress,
        bucket: :running,
        work_state: :paused,
        lifecycle: :running,
        terminal?: false,
        runtime_seconds: 1_800,
        percent: 40,
        tracker_paused: true,
        pause_reason: :operator_hold,
        evidence: {:commit, "9f0e1d2 redaction guard wip"}
      },
      # ── STUCK (Codex, unresponsive) ────────────────────────────────────
      %{
        number: 120,
        title: "Add CI check: selfhost-api builds without premium",
        build_lane: "platform",
        complexity: 3,
        agent_family: :codex,
        backend: :codex_cli,
        requested_model: "Sol 5.6",
        resolved_model: "Sol 5.6",
        effort: :standard,
        tracker_state: :in_progress,
        bucket: :running,
        work_state: nil,
        lifecycle: :running,
        terminal?: false,
        runtime_seconds: 900,
        percent: 30,
        waiting_reason: :unresponsive,
        stuck_reason: :unresponsive,
        evidence: {:log, "no output for 14m"}
      },
      # ── QUEUED (Claude, idle bucket) ───────────────────────────────────
      %{
        number: 113,
        title: "Set up Postgres and Drizzle migration harness",
        build_lane: "platform",
        complexity: 3,
        agent_family: :claude,
        backend: :claude_code,
        requested_model: "Sonnet 4.6",
        resolved_model: "Sonnet 4.6",
        effort: :standard,
        tracker_state: :queued,
        bucket: :idle,
        work_state: nil,
        lifecycle: :queued,
        terminal?: false,
        runtime_seconds: 0,
        percent: 0,
        waiting_reason: :awaiting_dispatch,
        evidence: {:queue, "awaiting executor slot"}
      },
      # ── FINISHED (Codex, terminal) ─────────────────────────────────────
      %{
        number: 103,
        title: "Create domain primitives and AssetAmount types",
        build_lane: "core",
        complexity: 2,
        agent_family: :codex,
        backend: :codex_cli,
        requested_model: "Sol 5.6",
        resolved_model: "Sol 5.6",
        effort: :standard,
        tracker_state: :merged,
        bucket: :idle,
        work_state: nil,
        lifecycle: :completed,
        terminal?: true,
        runtime_seconds: 3_200,
        percent: 100,
        evidence: {:pull_request, "#301 merged"}
      },
      # ── ACTIVE #2 (Claude, early) ──────────────────────────────────────
      %{
        number: 117,
        title: "Scaffold React Vite web app shell",
        build_lane: "web",
        complexity: 2,
        agent_family: :claude,
        backend: :claude_code,
        requested_model: "Sonnet 4.6",
        resolved_model: "Sonnet 4.6",
        effort: :standard,
        tracker_state: :in_progress,
        bucket: :running,
        work_state: :allocated,
        lifecycle: :running,
        terminal?: false,
        runtime_seconds: 600,
        percent: 15,
        evidence: {:commit, "3c4d5e6 vite shell"}
      }
    ]
  end

  # ── fleet_fun ────────────────────────────────────────────────────────────
  @spec fleet() :: map()
  def fleet do
    specs = specs()
    running = specs |> Enum.filter(&(&1.bucket == :running)) |> Enum.map(&fleet_row/1)
    retrying = specs |> Enum.filter(&(&1.bucket == :retrying)) |> Enum.map(&fleet_row/1)
    idle = specs |> Enum.filter(&(&1.bucket == :idle)) |> Enum.map(&fleet_row/1)

    %{
      generated_at: @generated_at,
      counts: %{running: length(running), retrying: length(retrying), idle: length(idle)},
      running: running,
      retrying: retrying,
      idle: idle,
      agent_totals: %{seconds_running: specs |> Enum.map(& &1.runtime_seconds) |> Enum.sum()}
    }
  end

  # ── membership_fun ───────────────────────────────────────────────────────
  @spec membership() :: map()
  def membership do
    %{
      generation: @generated_at,
      health: :healthy,
      health_message: nil,
      freshness: %{status: :fresh, observed_at: @generated_at},
      truncated?: false,
      members:
        Enum.map(specs(), fn spec ->
          %{
            identity: identity(spec.number),
            lifecycle: spec.lifecycle,
            terminal?: spec.terminal?,
            first_observed_at: @generated_at,
            last_observed_at: @generated_at
          }
        end)
    }
  end

  # ── activity_fun ─────────────────────────────────────────────────────────
  @spec activity() :: map()
  def activity do
    %{
      generation: @generated_at,
      health: :healthy,
      freshness: %{status: :fresh, observed_at: @generated_at},
      entries:
        Enum.map(specs(), fn spec ->
          {kind, name} = spec.evidence

          %{
            identity: identity(spec.number),
            progress: %{
              status: :known,
              percent: spec.percent,
              source: :heuristic,
              freshness: %{status: :fresh, observed_at: @generated_at}
            },
            latest_evidence: %{
              status: :known,
              source: %{kind: kind, name: name},
              freshness: %{status: :fresh, observed_at: @generated_at}
            }
          }
        end)
    }
  end

  # ── helpers ──────────────────────────────────────────────────────────────
  defp fleet_row(spec) do
    %{
      identity: identity(spec.number),
      title: spec.title,
      url: "https://github.com/#{@owner}/#{@repository}/issues/#{spec.number}",
      state: spec.tracker_state,
      backend: spec.backend,
      agent_family: spec.agent_family,
      requested_model: spec.requested_model,
      resolved_model: spec.resolved_model,
      effort: spec.effort,
      complexity: spec.complexity,
      build_lane: spec.build_lane,
      work_state: spec.work_state,
      runtime_seconds: spec.runtime_seconds,
      waiting_reason: Map.get(spec, :waiting_reason),
      tracker_paused: Map.get(spec, :tracker_paused, false),
      pause_reason: Map.get(spec, :pause_reason),
      alert_reason: Map.get(spec, :alert_reason),
      stuck_reason: Map.get(spec, :stuck_reason),
      open_decision_count: Map.get(spec, :open_decision_count, 0),
      open_decision_count_health: :available,
      started_at: @generated_at
    }
  end

  defp identity(number) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: @owner,
      repository: @repository,
      provider_id: "PVTI_demo_#{number}",
      database_id: number,
      identifier: Integer.to_string(number),
      reason: nil
    }
  end
end
