defmodule Aiur.SystemPressureTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO
  alias Aiur.{SystemLoad, SystemPressure}

  test "reads CPU some averages, ignoring full and other windows" do
    Application.put_env(:aiur, :cpu_pressure_source_override, fn ->
      {:ok, "some avg10=25.42 avg60=2.65 avg300=8.1 total=123\nfull avg10=99.00 avg60=99.00 avg300=99.00 total=456\n"}
    end)

    assert SystemPressure.cpu() == %{avg10: 25.42, avg60: 2.65}
  end

  test "unreadable and malformed pressure never becomes zero" do
    Application.put_env(:aiur, :cpu_pressure_source_override, fn -> {:error, :enoent} end)
    assert SystemPressure.cpu() == :unavailable

    for contents <- ["", "full avg10=0 avg60=0", "some avg10=0", "some avg10=NaN avg60=0", "some avg10=0 avg60=-1", "some avg10=0 avg60=101", "some avg10=0 avg60=2junk", "some avg10=0 avg60=2 broken"] do
      assert SystemPressure.parse(contents) == :unavailable
    end
  end

  test "status renders the measured pressure, memory, thresholds and sample age" do
    capacity = %{
      cpu_pressure: %{avg10: 35.1, avg60: 21.5},
      pressure_threshold: 20.0,
      pressure_target: 10.0,
      memory_mb: 3072,
      memory_threshold_mb: 4096,
      load_sampled_at_ms: System.monotonic_time(:millisecond) - 5_000
    }

    output = capture_io(fn -> SystemLoad.print_dispatch_sample(capacity) end)
    assert output =~ "avg10=35.1% avg60=21.5% threshold=20.0% target=10.0%"
    assert output =~ "available_mb=3072 threshold_mb=4096"
    assert output =~ "sampled=5s ago"
  end

  test "status explicitly names unavailable PSI and unknown memory rather than plausible defaults" do
    output = capture_io(fn -> SystemLoad.print_dispatch_sample(%{cpu_pressure: :unavailable, memory_mb: :unavailable, memory_threshold_mb: 4096}) end)
    assert output =~ "CPU PSI unavailable; load-average fallback"
    assert output =~ "available_mb=:unavailable threshold_mb=4096"
    assert output =~ "sampled=unavailable"
  end
end
