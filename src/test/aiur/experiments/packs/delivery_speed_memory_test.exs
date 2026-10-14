defmodule Aiur.Experiments.Packs.DeliverySpeedMemoryTest do
  use ExUnit.Case, async: false
  alias Aiur.Experiments.Packs.DeliverySpeed
  alias Aiur.RunTelemetry.Dataset

  @window %{start: ~U[2026-10-09 09:00:00Z], end: ~U[2026-10-09 14:00:00Z]}
  @fixtures Path.expand("../../../fixtures/experiments/telemetry", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "delivery-memory-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    {:ok, prior} = Dataset.build(Path.join(@fixtures, "boot-a.ndjson"))
    summary = Path.join(root, "prior.json")
    File.write!(summary, Jason.encode!(Aiur.JSONSafe.normalize(prior)))
    owner = self()

    ctx = %{
      telemetry_enabled: true,
      boot_id: "boot-b",
      telemetry_path: Path.join(@fixtures, "boot-b.ndjson"),
      summary_boot_ids: fn -> ["boot-a"] end,
      summary_path: fn "boot-a" -> summary end,
      telemetry_reader_options: [on_open: fn path -> send(owner, {:opened_summary, path}) end]
    }

    %{ctx: ctx, summary: summary, root: root}
  end

  test "second evaluation reuses bounded retained history and keeps first dispatch", %{ctx: ctx, summary: summary} do
    for _iteration <- 1..2 do
      {coverage, rows} = DeliverySpeed.observations(["start_to_merge"], @window, ctx)["start_to_merge"]
      assert coverage.state == :captured
      assert Enum.find(rows, &(&1.unit_id == "ticket:101")).value == 9_000_000
      assert Enum.find(rows, &(&1.unit_id == "ticket:101")).at == ~U[2026-10-09 10:00:00Z]
    end

    assert_received {:opened_summary, ^summary}
    refute_received {:opened_summary, _path}
  end

  test "changed summary metadata invalidates cached history", %{ctx: ctx, summary: summary} do
    DeliverySpeed.observations(["start_to_merge"], @window, ctx)
    File.write!(summary, "\n", [:append])
    DeliverySpeed.observations(["start_to_merge"], @window, ctx)
    assert_received {:opened_summary, ^summary}
    assert_received {:opened_summary, ^summary}
    refute_received {:opened_summary, _path}
  end

  test "an oversized earlier summary does not consume a complete summary's byte budget", %{ctx: ctx, summary: summary, root: root} do
    budget = 65_536
    large = Path.join(root, "large.json")
    File.write!(large, Jason.encode!(%{ignored: String.duplicate("x", budget * 2)}))
    assert File.stat!(large).size > budget
    assert File.stat!(summary).size < budget
    opts = Keyword.put(ctx.telemetry_reader_options, :max_bytes, budget)

    ctx = %{
      ctx
      | telemetry_path: Path.join(root, "missing"),
        summary_boot_ids: fn -> ["large", "small"] end,
        summary_path: fn
          "large" -> large
          "small" -> summary
        end,
        telemetry_reader_options: opts
    }

    for _ <- 1..2 do
      assert {%{state: :partial}, rows} = DeliverySpeed.observations(["start_to_merge"], @window, ctx)["start_to_merge"]
      assert Enum.find(rows, &(&1.unit_id == "ticket:102")).value == 2_400_000
    end

    assert_received {:opened_summary, ^large}
    assert_received {:opened_summary, ^summary}
    refute_received {:opened_summary, _path}
  end

  test "warning volume does not exhaust the delivery projection", %{ctx: ctx, summary: summary} do
    {:ok, dataset} = Dataset.build(Path.join(@fixtures, "boot-a.ndjson"))
    base = hd(dataset.records)
    warnings = Enum.map(1..1_000, fn n -> %{base | kind: "warning", record_id: "warning:#{n}", attributes: %{"detail" => String.duplicate("x", 5_000)}} end)
    raw = Aiur.JSONSafe.normalize(%{dataset | records: warnings ++ dataset.records})
    File.write!(summary, Jason.encode!(raw))
    assert File.stat!(summary).size > 4_194_304
    assert {%{state: :partial}, rows} = DeliverySpeed.observations(["start_to_merge"], @window, ctx)["start_to_merge"]
    assert Enum.find(rows, &(&1.unit_id == "ticket:101")).value == 9_000_000
  end

  test "twenty-four immutable summaries remain cached independently", %{ctx: ctx, root: root} do
    {:ok, dataset} = Dataset.build(Path.join(@fixtures, "boot-a.ndjson"))
    boots = Enum.map(1..24, &Integer.to_string/1)
    for boot <- boots, do: File.write!(Path.join(root, boot), Jason.encode!(Aiur.JSONSafe.normalize(dataset)))
    ctx = %{ctx | summary_boot_ids: fn -> boots end, summary_path: &Path.join(root, &1)}

    for _ <- 1..2 do
      assert {%{state: :captured}, rows} = DeliverySpeed.observations(["start_to_merge"], @window, ctx)["start_to_merge"]
      assert Enum.find(rows, &(&1.unit_id == "ticket:101")).value == 9_000_000
    end

    for boot <- boots do
      path = Path.join(root, boot)
      assert_received {:opened_summary, ^path}
    end

    refute_received {:opened_summary, _path}
  end

  test "truncated earlier history keeps live observations with partial coverage", %{ctx: ctx} do
    opts = Keyword.put(ctx.telemetry_reader_options, :max_records, 1)
    ctx = Map.put(ctx, :telemetry_reader_options, opts)
    assert {%{state: :partial}, [_ | _]} = DeliverySpeed.observations(["start_to_merge"], @window, ctx)["start_to_merge"]
  end
end
