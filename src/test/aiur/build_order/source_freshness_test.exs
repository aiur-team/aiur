defmodule Aiur.BuildOrder.SourceFreshnessTest do
  # Pins the single helper #4753 shipped; it passes with #4504's changes reverted.
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.SourceFreshness

  test "ms converts DateTimes, ISO strings and integers; anything else is unknown" do
    at = ~U[2026-10-07 12:00:00.123Z]
    ms = DateTime.to_unix(at, :millisecond)

    assert SourceFreshness.ms(at) == ms
    assert SourceFreshness.ms(DateTime.to_iso8601(at)) == ms
    assert SourceFreshness.ms(ms) == ms
    assert SourceFreshness.ms("not a time") == nil
    assert SourceFreshness.ms(nil) == nil
    assert SourceFreshness.ms(:unknown) == nil
  end
end
