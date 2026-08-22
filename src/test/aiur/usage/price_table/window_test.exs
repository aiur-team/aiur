defmodule Aiur.Usage.PriceTable.WindowTest do
  use ExUnit.Case, async: true

  alias Aiur.Usage.PriceTable.Data
  alias Aiur.Usage.PriceTable.Window

  # Pinned UTC instants — the tests never read the real clock.
  @schedule Data.window_schedule(:deepseek)

  # 2026-08-24 is a Monday; 2026-08-22 is a Saturday (Beijing), 2026-08-23
  # Sunday (Beijing). The weekend rule is effective 00:00 Beijing 2026-08-23
  # = 16:00 UTC 2026-08-22.
  @weekday_peak_01 ~U[2026-08-24 01:00:00Z]
  @weekday_peak_04_exclusive ~U[2026-08-24 04:00:00Z]
  @weekday_peak_06 ~U[2026-08-24 06:00:00Z]
  @weekday_peak_10_exclusive ~U[2026-08-24 10:00:00Z]
  @weekday_off_peak ~U[2026-08-24 12:00:00Z]
  @beijing_saturday_utc ~U[2026-08-29 02:00:00Z]
  @beijing_sunday_utc ~U[2026-08-30 12:00:00Z]
  @beijing_friday_evening_utc ~U[2026-08-28 20:00:00Z]
  @pre_weekend_rule_beijing_saturday ~U[2026-08-22 02:00:00Z]

  describe "classify/2 with the DeepSeek schedule" do
    test "weekday peak windows (01:00-04:00 and 06:00-10:00 UTC) are peak, inclusive start" do
      assert Window.classify(@weekday_peak_01, @schedule) == :peak
      assert Window.classify(@weekday_peak_06, @schedule) == :peak
      assert Window.classify(~U[2026-08-24 03:59:59Z], @schedule) == :peak
      assert Window.classify(~U[2026-08-24 09:59:59Z], @schedule) == :peak
    end

    test "peak windows are finish-exclusive; every other weekday hour is off-peak" do
      assert Window.classify(@weekday_peak_04_exclusive, @schedule) == :off_peak
      assert Window.classify(@weekday_peak_10_exclusive, @schedule) == :off_peak
      assert Window.classify(@weekday_off_peak, @schedule) == :off_peak
      assert Window.classify(~U[2026-08-24 00:59:59Z], @schedule) == :off_peak
    end

    test "all of Saturday and Sunday Beijing time is off-peak, overriding daily windows" do
      # Beijing Saturday 10:00 — inside what would be a daily peak window in UTC.
      assert Window.classify(@beijing_saturday_utc, @schedule) == :off_peak
      # Beijing Sunday 20:00.
      assert Window.classify(@beijing_sunday_utc, @schedule) == :off_peak
      # Beijing Saturday 04:00 (a UTC hour inside 01:00-04:00 on Friday's date).
      assert Window.classify(@beijing_friday_evening_utc, @schedule) == :off_peak
    end

    test "the weekend rule applies only on/after its effective date" do
      # Beijing Saturday 10:00 on 2026-08-22, BEFORE the rule took effect at
      # 00:00 Beijing 2026-08-23: the daily peak window still applies.
      assert Window.classify(@pre_weekend_rule_beijing_saturday, @schedule) == :peak
      # At 16:00 UTC 2026-08-22 the rule takes effect (Beijing Sunday 00:00).
      assert Window.classify(~U[2026-08-22 16:00:00Z], @schedule) == :off_peak
      # The same 02:00 UTC hour is peak on 2026-08-22 (a pre-rule Beijing
      # Saturday) but off-peak on 2026-08-29 (a post-rule Beijing Saturday):
      # the weekend rule — not just the clock hour — decides.
      assert Window.classify(~U[2026-08-22 02:00:00Z], @schedule) == :peak
      assert Window.classify(~U[2026-08-29 02:00:00Z], @schedule) == :off_peak
    end
  end

  describe "classify/2 with malformed schedule data" do
    test "an unparseable schedule is :unknown, never a guessed window" do
      assert Window.classify(@weekday_peak_01, %{}) == :unknown
      assert Window.classify(@weekday_peak_01, %{utc_offset_hours: 8}) == :unknown
      assert Window.classify(@weekday_peak_01, %{weekday_peak_windows_utc: []}) == :unknown
      assert Window.classify(@weekday_peak_01, %{weekday_peak_windows_utc: [{~T[01:00:00], ~T[01:00:00]}]}) == :unknown
      assert Window.classify(@weekday_peak_01, "not a schedule") == :unknown
    end
  end

  describe "resolve/2" do
    test "resolves the occurrence window for a windowed provider" do
      assert Window.resolve(:deepseek, @weekday_peak_01) == :peak
      assert Window.resolve(:deepseek, @weekday_off_peak) == :off_peak
      assert Window.resolve(:deepseek, @beijing_saturday_utc) == :off_peak
    end

    test "a missing occurrence time or unparseable window resolves to the conservative peak" do
      assert Window.resolve(:deepseek, nil) == :peak
    end

    test "a provider with no windowed schedule resolves to nil" do
      assert Window.resolve(:codex, @weekday_peak_01) == nil
      assert Window.resolve(:claude, @weekday_peak_01) == nil
    end
  end

  describe "next_boundary/2" do
    test "the next weekday peak window is the next boundary from a weekday off-peak instant" do
      # Monday 12:00 UTC is off-peak; the next flip is Tuesday 01:00 UTC.
      assert {:ok, ~U[2026-08-25 01:00:00Z], :peak} = Window.next_boundary(~U[2026-08-24 12:00:00Z], @schedule)
    end

    test "the next flip from inside a peak window is the end of that window" do
      # Monday 02:00 is inside 01:00-04:00; the window ends at 04:00 UTC.
      assert {:ok, ~U[2026-08-24 04:00:00Z], :off_peak} = Window.next_boundary(~U[2026-08-24 02:00:00Z], @schedule)
    end

    test "from a weekend off-peak instant the next flip is the first weekday peak window" do
      # Saturday noon (Beijing Saturday 20:00) is off-peak; the weekend ends
      # Sunday 16:00 UTC but the rate stays off-peak until Monday 01:00 UTC.
      assert {:ok, ~U[2026-08-31 01:00:00Z], :peak} = Window.next_boundary(~U[2026-08-29 12:00:00Z], @schedule)
    end

    test "an unparseable schedule cannot report a boundary" do
      assert {:error, :unknown_window} = Window.next_boundary(~U[2026-08-24 12:00:00Z], %{})
    end
  end

  test "the Beijing offset is a named constant with the no-DST justification documented" do
    assert Data.beijing_utc_offset_hours() == 8
    assert @schedule.utc_offset_hours == 8
  end
end
