defmodule Aiur.UnitsCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.{TrackerIdentity, UnitsCLI}

  @identity %TrackerIdentity{
    status: :joinable,
    kind: :github,
    owner: "aiur-team",
    repository: "aiur",
    provider_id: "node-1594",
    identifier: "1594",
    reason: nil
  }

  test "projects the same Units rows through a stable, fresh snapshot envelope" do
    assert {:ok, envelope} =
             UnitsCLI.build(
               payload_fun: fn -> %{units: ready_catalog()} end,
               scope: :all,
               conditions: ["queued"],
               now: ~U[2026-08-09 12:05:00Z]
             )

    assert envelope["schema_version"] == 1
    assert envelope["page"] == "units"
    assert envelope["snapshot"]["captured_at"] == "2026-08-09T12:05:00Z"
    assert envelope["request"] == %{"conditions" => ["queued"], "scope" => "all"}

    assert envelope["sources"]["units_catalog"] == %{
             "age_ms" => 300_000,
             "freshness" => "current",
             "observed_at" => "2026-08-09T12:00:00Z",
             "partial" => false,
             "reasons" => [],
             "state" => "available"
           }

    assert [row] = envelope["data"]["view"]["rows"]
    assert row["title"] == "Visible but not running"
    assert row["lifecycle"] == "queued"
    assert row["backend"] == "codex"
    assert row["complexity"] == 3
    assert row["presentation"]["unit"]["provider"] == "Codex"
    assert row["presentation"]["unit"]["priority"] == "MED"
    assert row["presentation"]["command"]["control"]["label"] == "Unit is retrying"

    output =
      capture_io(fn ->
        assert 0 ==
                 UnitsCLI.run(
                   payload_fun: fn -> %{units: ready_catalog()} end,
                   scope: :all,
                   conditions: ["queued"],
                   now: ~U[2026-08-09 12:05:00Z],
                   json: true
                 )
      end)

    assert Jason.decode!(output)["data"]["view"]["rows"] |> length() == 1

    human_output =
      capture_io(fn ->
        assert 0 ==
                 UnitsCLI.run(
                   payload_fun: fn -> %{units: ready_catalog()} end,
                   scope: :all,
                   conditions: ["queued"],
                   now: ~U[2026-08-09 12:05:00Z]
                 )
      end)

    assert human_output =~ "ID: 1594"
    assert human_output =~ "Unit: Codex · Cx:3 · gpt-5.6 · MED"
    assert human_output =~ "Ticket: Visible but not running (meta)"
    assert human_output =~ "Latest: agent_event; 60%; runtime unknown"
    assert human_output =~ "Command: Unit is retrying; chat unavailable; remote control unavailable; read-only"
  end

  test "rejects policy-only conditions that the Units page does not expose" do
    assert {:error, message} = UnitsCLI.build(conditions: ["stuck"])
    assert message =~ "active, alert, paused, queued, or finished"
  end

  test "keeps an unavailable catalog unobserved instead of serializing a confident empty row set" do
    assert {:ok, envelope} = UnitsCLI.build(payload_fun: fn -> %{units: unavailable_catalog()} end)

    assert envelope["sources"]["units_catalog"] == %{
             "age_ms" => nil,
             "freshness" => "unknown",
             "observed_at" => nil,
             "partial" => false,
             "reasons" => ["catalog_unavailable"],
             "state" => "unavailable"
           }

    assert envelope["data"]["catalog"]["snapshot"]["rows"] == nil
    assert envelope["data"]["view"]["rows"] == nil
    assert envelope["data"]["view"]["total_count"] == nil
  end

  test "distinguishes observed empty and partial catalog states" do
    assert {:ok, empty} = UnitsCLI.build(payload_fun: fn -> %{units: empty_catalog()} end)
    assert empty["sources"]["units_catalog"]["state"] == "empty"
    assert empty["data"]["view"]["rows"] == []

    assert {:ok, partial} = UnitsCLI.build(payload_fun: fn -> %{units: partial_catalog()} end)

    assert partial["sources"]["units_catalog"] == %{
             "age_ms" => nil,
             "freshness" => "unknown",
             "observed_at" => nil,
             "partial" => true,
             "reasons" => ["catalog_partial"],
             "state" => "partial"
           }
  end

  defp ready_catalog do
    %{
      status: :ready,
      message: nil,
      truncated?: false,
      snapshot: %{
        freshness: %{membership: %{status: :fresh, observed_at: ~U[2026-08-09 12:00:00Z]}},
        rows: [queued_row()]
      }
    }
  end

  defp unavailable_catalog do
    %{
      status: :unavailable,
      message: "current-run membership is unavailable",
      truncated?: false,
      snapshot: %{freshness: %{membership: %{status: :unavailable}}, rows: []}
    }
  end

  defp empty_catalog do
    %{
      status: :empty,
      message: "No units have been observed in this run.",
      truncated?: false,
      snapshot: %{freshness: %{membership: %{status: :fresh}}, rows: []}
    }
  end

  defp partial_catalog do
    %{
      status: :ready,
      message: nil,
      truncated?: true,
      snapshot: %{freshness: %{membership: %{status: :fresh}}, rows: [queued_row()]}
    }
  end

  defp queued_row do
    %{
      identity: @identity,
      title: "Visible but not running",
      lifecycle: :queued,
      terminal?: false,
      replacement_boundary?: false,
      tracker_state: "todo",
      backend: "codex",
      agent_family: "codex",
      requested_model: "gpt-5.6",
      resolved_model: nil,
      effort: "high",
      complexity: 3,
      build_lane: "meta",
      reasons: %{alert: nil, blocking: nil, pause: nil, stuck: nil, waiting: :awaiting_dispatch},
      runtime: %{bucket: :retrying, work_state: :waiting, waiting_reason: :awaiting_dispatch, runtime_seconds: nil},
      progress: %{status: :known, percent: 60},
      latest_evidence: %{status: :known, source: :agent_event}
    }
  end
end
