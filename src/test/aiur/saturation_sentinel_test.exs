defmodule Aiur.SaturationSentinelTest do
  use ExUnit.Case, async: true

  alias Aiur.SaturationSentinel

  # A minimal State-shaped map for the pure escalation decision.
  defp state(overrides \\ []) do
    Map.merge(
      %{
        threshold_per_scheduler: 1.5,
        armed: false,
        last_record_ms: 0,
        cooldown_ms: 30_000,
        now_ms: 0
      },
      Map.new(overrides)
    )
  end

  describe "should_record?/3" do
    test "enters a surge when load crosses the per-scheduler threshold" do
      # 16 schedulers * 1.5 = escalate at load >= 24 (the #465 gate line).
      assert :enter = SaturationSentinel.should_record?(24.0, 16, state())
      assert :enter = SaturationSentinel.should_record?(50.0, 16, state())
    end

    test "skips below the threshold while disarmed" do
      assert :skip = SaturationSentinel.should_record?(10.0, 16, state())
      assert :skip = SaturationSentinel.should_record?(0.1, 16, state())
    end

    test "disarms after the load crosses back below the threshold" do
      armed = state(armed: true, last_record_ms: 0, now_ms: 1_000)
      assert :disarm = SaturationSentinel.should_record?(10.0, 16, armed)
    end

    test "records on cooldown expiry while still armed and above the threshold" do
      armed = state(armed: true, last_record_ms: 0, now_ms: 60_000)
      assert :record = SaturationSentinel.should_record?(25.0, 16, armed)
    end

    test "skips within the cooldown window while still armed" do
      armed = state(armed: true, last_record_ms: 0, now_ms: 5_000)
      assert :skip = SaturationSentinel.should_record?(25.0, 16, armed)
    end

    test "unavailable load never escalates or disarms" do
      assert :skip = SaturationSentinel.should_record?(:unavailable, 16, state())
      assert :skip = SaturationSentinel.should_record?(:unavailable, 16, state(armed: true))
    end
  end

  describe "snapshot/1" do
    test "returns VM-internal + host diagnostics with an injectable load" do
      snap = SaturationSentinel.snapshot(load_fun: fn -> 27.5 end)

      assert snap.load1 == 27.5
      assert is_integer(snap.schedulers_online) and snap.schedulers_online > 0
      assert is_integer(snap.process_count) and snap.process_count > 0
      assert is_integer(snap.port_count)
      assert is_integer(snap.atom_count) and snap.atom_count > 0
      assert is_integer(snap.ets_tables)
      assert is_integer(snap.run_queue)
      assert is_list(snap.memory) and Keyword.keyword?(snap.memory)
      assert snap.ts =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end
  end

  describe "record/2" do
    test "appends one JSON line per sample to the target file" do
      dir = Aiur.TestSupport.tmp_root!("aiur-sat")
      path = Path.join(dir, "saturation.log")
      snap = %{load1: 1.0, process_count: 2}

      assert :ok = SaturationSentinel.record(path, snap)
      assert :ok = SaturationSentinel.record(path, snap)

      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2
      assert Jason.decode!(List.first(lines))["load1"] == 1.0
    end

    test "never raises on an unwritable target (fail-open)" do
      assert :ok = SaturationSentinel.record("/proc/aiur-saturation-test/saturation.log", %{})
    end
  end

  describe "file_path/0" do
    test "resolves beside the configured daemon log" do
      original = Application.get_env(:aiur, :log_file)
      Application.put_env(:aiur, :log_file, "/tmp/aiur-logs/log/aiur.log")
      on_exit(fn -> Application.put_env(:aiur, :log_file, original) end)

      assert SaturationSentinel.file_path() == "/tmp/aiur-logs/log/saturation.log"
    end
  end
end
