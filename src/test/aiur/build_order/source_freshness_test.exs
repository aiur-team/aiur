defmodule Aiur.BuildOrder.SourceFreshnessTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.SourceFreshness
  alias AiurWeb.Build.Usage

  test "one conversion; only SourceFreshness passes integers through" do
    at = ~U[2026-10-07 12:00:00.123Z]
    ms = DateTime.to_unix(at, :millisecond)

    for convert <- [&SourceFreshness.ms/1, &Usage.ms/1] do
      assert convert.(at) == ms
      assert convert.(DateTime.to_iso8601(at)) == ms
      assert convert.("not a time") == nil
      assert convert.(nil) == nil
    end

    assert SourceFreshness.ms(ms) == ms
    assert Usage.ms(ms) == nil
  end
end
