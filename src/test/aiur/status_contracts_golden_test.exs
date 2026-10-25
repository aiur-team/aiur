defmodule Aiur.StatusContractsGoldenTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.ExtensionsTestSupport
  alias Aiur.ExtensionsTestSupport.StaticOrchestrator
  alias Aiur.Handoff.CLI, as: HandoffCLI
  alias Aiur.TestSupport.GroupedScopes, as: GS
  alias Aiur.TrackerIdentity
  alias AiurWeb.Api.Usage.TicketUsage
  alias AiurWeb.Api.UsageProgress
  alias AiurWeb.Presenter

  @fixtures Path.expand("../../../packages/aiur-contracts/fixtures", __DIR__)
  @now ~U[2026-10-23 12:00:00Z]

  test "live JSON encoders match the TypeScript package golden fixtures" do
    orchestrator = Module.concat(__MODULE__, :StaticOrchestrator)
    snapshot = status_snapshot()
    capabilities = :ets.new(:status_contracts_golden_capabilities, [:set])
    :ets.insert(capabilities, {:report, {%{capabilities: %{}}, System.monotonic_time(:millisecond), nil}})
    start_supervised!({StaticOrchestrator, name: orchestrator, snapshot: snapshot})

    status =
      orchestrator
      |> Presenter.state_payload(1_000, status_opts(capabilities))
      |> Map.put(:generated_at, DateTime.to_iso8601(@now))
      |> stabilize_snapshot_freshness()

    assert {:ok, ticket} = Presenter.issue_payload("5698", orchestrator, 1_000)
    assert {:ok, usage} = TicketUsage.fetch("5698", usage_opts())
    assert {:ok, progress} = UsageProgress.payload("5698", progress_opts())

    fixtures = %{
      "agents.v1.json" => agents_payload(),
      "status.v1.json" => status,
      "ticket.v1.json" => ticket,
      "ticket-usage.v1.json" => usage,
      "ticket-progress.v1.json" => progress
    }

    Enum.each(fixtures, fn {name, payload} -> assert_golden(name, payload) end)
  end

  defp agents_payload do
    output = capture_io(fn -> HandoffCLI.agents(snapshot: agents_snapshot()) end)
    [json | _markers] = String.split(output, "\n", trim: true)
    Jason.decode!(json)
  end

  defp agents_snapshot do
    %{
      running: [
        %{
          identifier: "5698",
          issue_id: "I_5698",
          session_id: "session-5698",
          provider_pid: 12_345,
          codex_app_server_pid: nil,
          adopted_from: "handoff-7"
        }
      ]
    }
  end

  defp status_snapshot do
    running =
      ExtensionsTestSupport.static_snapshot(workspace_path: "/var/lib/aiur/5698")
      |> Map.fetch!(:running)
      |> List.first()
      |> Map.merge(%{
        identifier: "5698",
        issue_id: "I_5698",
        state: "in-progress",
        session_id: "session-5698",
        started_at: @now,
        last_codex_timestamp: @now,
        worker_host: "worker.example",
        workspace_path: "/var/lib/aiur/5698"
      })

    ExtensionsTestSupport.static_snapshot()
    |> Map.merge(%{
      running: [running],
      retrying: [],
      idle: [],
      agent_totals: %{seconds_running: 42},
      globally_paused: false,
      observations: nil,
      daemon_started_at: DateTime.to_iso8601(@now)
    })
  end

  defp status_opts(capabilities) do
    [
      table: capabilities,
      decision_history_fun: fn -> [] end,
      recent_merge_snapshot_fun: fn ->
        %{
          merges: [],
          health: :writable,
          reconciliation: %{status: :complete, partial?: false, pages_fetched: 0}
        }
      end,
      telemetry_file_fun: fn -> "/var/lib/aiur/missing-telemetry.ndjson" end
    ]
  end

  defp stabilize_snapshot_freshness(payload) do
    Map.update!(payload, :snapshot_freshness, fn freshness ->
      Map.merge(freshness, %{
        observed_at: DateTime.to_iso8601(@now),
        age_ms: 0,
        age_seconds: 0
      })
    end)
  end

  defp usage_opts do
    identity = GS.identity("aiur-team", "aiur", 5698)
    records = [GS.claude_record(1, ticket: identity, run_id: "run-5698", tokens: %{input: 120, output: 30}, cost: GS.money("0.42"))]

    [
      scan_fun: fn options -> {:ok, Enum.filter(records, &(&1.position > Keyword.fetch!(options, :after)))} end,
      cells_snapshot_fun: fn -> GS.source(records) end,
      repository_fun: fn -> {:ok, {"aiur-team", "aiur"}} end
    ]
  end

  defp progress_opts do
    identity = %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "aiur-team",
      repository: "aiur",
      provider_id: "I_5698",
      identifier: "5698",
      reason: nil
    }

    entry = %{
      identity: identity,
      stage: %{status: :known, value: :work, observed_at: @now},
      progress: %{
        status: :known,
        percent: 60,
        source: :checkin,
        freshness: :fresh,
        occurred_at: @now,
        observed_at: @now
      }
    }

    history = [
      %{
        kind: "self",
        id: 11,
        topic: "ticket.5698.agent.progress.checkin",
        label: "Progress check-in",
        body: "60%",
        timestamp: DateTime.to_iso8601(@now)
      }
    ]

    [
      activity_fun: fn -> %{entries: [entry]} end,
      retention_fun: fn -> %{} end,
      history_fun: fn "5698", _opts -> history end,
      now: @now
    ]
  end

  defp assert_golden(name, payload) do
    wire = payload |> Jason.encode!() |> Jason.decode!()
    path = Path.join(@fixtures, name)

    if System.get_env("AIUR_UPDATE_GOLDEN") == "1" do
      File.write!(path, Jason.encode!(wire, pretty: true) <> "\n")
    end

    assert wire == path |> File.read!() |> Jason.decode!()
  end
end
