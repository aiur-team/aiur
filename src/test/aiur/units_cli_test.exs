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
    assert human_output =~ "Latest: Awaiting dispatch; 60%; 5m"
    assert human_output =~ "Command: Unit is retrying; chat unavailable; remote control unavailable; read-only"
  end

  test "rejects policy-only conditions that the Units page does not expose" do
    assert {:ok, _envelope} = UnitsCLI.build(payload_fun: fn -> %{units: ready_catalog()} end, conditions: "active,alert,paused,queued,finished")
    assert {:error, message} = UnitsCLI.build(conditions: ["stuck"])
    assert message =~ "active, alert, paused, queued, or finished"
  end

  test "reports invalid scope errors through the CLI boundary" do
    error_output =
      capture_io(:stderr, fn ->
        assert 1 == UnitsCLI.run(scope: "invalid")
      end)

    assert error_output =~ "aiur: units accepts --scope live, unfinished, all, or none"
  end

  test "matches every page scope and visible condition" do
    opts = [payload_fun: fn -> %{units: mixed_catalog()} end]

    assert ids(opts ++ [scope: :live]) == ["1600", "1601", "1602"]
    assert ids(opts ++ [scope: :unfinished]) == ["1600", "1601", "1602", "1603"]
    assert ids(opts ++ [scope: :all]) == ["1600", "1601", "1602", "1603", "1604"]
    assert ids(opts ++ [scope: :none]) == []

    assert ids(opts ++ [scope: :all, conditions: ["active"]]) == ["1600", "1601"]
    assert ids(opts ++ [scope: :all, conditions: ["alert"]]) == ["1601"]
    assert ids(opts ++ [scope: :all, conditions: ["paused"]]) == ["1602"]
    assert ids(opts ++ [scope: :all, conditions: ["queued"]]) == ["1603"]
    assert ids(opts ++ [scope: :all, conditions: ["finished"]]) == ["1604"]
    assert ids(opts ++ [scope: :none, conditions: ["queued"]]) == []
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

  test "accepts serialized catalog payloads and fails closed when loading fails" do
    assert {:ok, serialized} = UnitsCLI.build(payload_fun: fn -> %{"units" => ready_catalog()} end)
    assert serialized["sources"]["units_catalog"]["state"] == "available"

    for payload_fun <- [fn -> %{} end, fn -> raise "payload unavailable" end, fn -> throw(:payload_unavailable) end] do
      assert {:ok, envelope} = UnitsCLI.build(payload_fun: payload_fun)
      assert envelope["sources"]["units_catalog"]["state"] == "unavailable"
      assert envelope["data"]["view"]["rows"] == nil
    end
  end

  test "normalizes serialized freshness timestamps without overstating unknown data" do
    current_catalog =
      ready_catalog()
      |> put_in([:snapshot, :freshness, :membership, :status], :current)
      |> put_in([:snapshot, :freshness, :membership, :observed_at], "2026-08-09T12:00:00Z")

    assert {:ok, current} =
             UnitsCLI.build(payload_fun: fn -> %{units: current_catalog} end, now: ~U[2026-08-09 12:05:00Z])

    assert current["sources"]["units_catalog"] |> Map.take(["freshness", "observed_at", "age_ms"]) == %{
             "age_ms" => 300_000,
             "freshness" => "current",
             "observed_at" => "2026-08-09T12:00:00Z"
           }

    invalid_catalog = put_in(current_catalog, [:snapshot, :freshness, :membership, :observed_at], "not-a-timestamp")

    assert {:ok, invalid} = UnitsCLI.build(payload_fun: fn -> %{units: invalid_catalog} end)
    assert invalid["sources"]["units_catalog"]["freshness"] == "unknown"
    assert invalid["sources"]["units_catalog"]["observed_at"] == nil
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

  test "reports stale and stale-partial catalogs without claiming current data" do
    assert {:ok, stale} = UnitsCLI.build(payload_fun: fn -> %{units: stale_catalog(false)} end, now: ~U[2026-08-09 12:05:00Z])

    assert stale["sources"]["units_catalog"] == %{
             "age_ms" => 300_000,
             "freshness" => "stale",
             "observed_at" => "2026-08-09T12:00:00Z",
             "partial" => false,
             "reasons" => ["catalog_stale"],
             "state" => "stale"
           }

    assert {:ok, stale_partial} = UnitsCLI.build(payload_fun: fn -> %{units: stale_catalog(true)} end, now: ~U[2026-08-09 12:05:00Z])

    assert stale_partial["sources"]["units_catalog"] == %{
             "age_ms" => 300_000,
             "freshness" => "stale",
             "observed_at" => "2026-08-09T12:00:00Z",
             "partial" => true,
             "reasons" => ["catalog_stale", "catalog_partial"],
             "state" => "stale"
           }
  end

  test "renders stale, unobserved, and zero-result states truthfully for human output" do
    stale_output =
      capture_io(fn ->
        assert 0 ==
                 UnitsCLI.run(
                   payload_fun: fn -> %{units: stale_catalog(true)} end,
                   now: ~U[2026-08-09 12:05:00Z]
                 )
      end)

    assert stale_output =~ "units_catalog: stale; freshness stale; age 300000ms"
    assert stale_output =~ "Warning: catalog_stale, catalog_partial"

    unavailable_output =
      capture_io(fn ->
        assert 0 == UnitsCLI.run(payload_fun: fn -> %{units: unavailable_catalog()} end)
      end)

    assert unavailable_output =~ "Units catalog unavailable; units have not been observed."

    zero_result_output =
      capture_io(fn ->
        assert 0 == UnitsCLI.run(payload_fun: fn -> %{units: ready_catalog()} end, scope: :none)
      end)

    assert zero_result_output =~ "No units match this valid scope and condition selection."
  end

  defp mixed_catalog do
    %{
      status: :ready,
      message: nil,
      truncated?: false,
      snapshot: %{
        freshness: %{membership: %{status: :fresh, observed_at: ~U[2026-08-09 12:00:00Z]}},
        rows: [
          row("1600", lifecycle: :running, runtime: %{bucket: :running, work_state: :working}),
          row("1601", lifecycle: :running, runtime: %{bucket: :running, work_state: :working}, reasons: %{alert: :needs_attention}),
          row("1602", lifecycle: :running, runtime: %{bucket: :running, work_state: :paused}, reasons: %{pause: :operator}),
          row("1603", lifecycle: :queued, runtime: %{bucket: :retrying, work_state: :waiting, waiting_reason: :awaiting_dispatch}),
          row("1604", lifecycle: :finished, terminal?: true, runtime: %{bucket: :finished, work_state: :completed})
        ]
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

  defp stale_catalog(truncated?) do
    %{
      status: :stale,
      message: "Units catalog is stale.",
      truncated?: truncated?,
      snapshot: %{
        freshness: %{membership: %{status: :stale, observed_at: ~U[2026-08-09 12:00:00Z]}},
        rows: [queued_row()]
      }
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
      timestamps: %{started_at: "2026-08-09T12:00:00Z"},
      progress: %{status: :known, percent: 60},
      latest_evidence: %{status: :known, source: %{kind: :queue, name: "Awaiting dispatch"}}
    }
  end

  defp ids(opts) do
    assert {:ok, envelope} = UnitsCLI.build(opts)
    Enum.map(envelope["data"]["view"]["rows"], & &1["identity"]["identifier"])
  end

  defp row(identifier, changes) do
    queued_row()
    |> Map.put(:reasons, %{alert: nil, blocking: nil, pause: nil, stuck: nil, waiting: nil})
    |> Map.merge(Map.new(changes))
    |> Map.put(:identity, %{@identity | identifier: identifier, provider_id: "node-#{identifier}"})
    |> Map.put(:title, "Unit #{identifier}")
    |> Map.update!(:reasons, &Map.merge(%{alert: nil, blocking: nil, pause: nil, stuck: nil, waiting: nil}, &1))
  end
end
