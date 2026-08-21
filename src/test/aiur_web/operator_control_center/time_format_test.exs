defmodule AiurWeb.OperatorControlCenter.TimeFormatTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.TimeFormat

  @instant ~U[2026-08-20 15:30:00Z]

  test "formats a UTC instant in the requested zone" do
    assert TimeFormat.format(@instant, "America/Los_Angeles") == "2026-08-20 08:30"
    assert TimeFormat.format(@instant, "Etc/UTC") == "2026-08-20 15:30"
  end

  test "nil renders unknown" do
    assert TimeFormat.format(nil, "America/Los_Angeles") == "unknown"
  end

  test "iso8601 shifts into the requested zone" do
    assert TimeFormat.iso8601(@instant, "America/Los_Angeles") == "2026-08-20T08:30:00-07:00"
    assert TimeFormat.iso8601(@instant, "Etc/UTC") == "2026-08-20T15:30:00Z"
  end

  test "iso8601 nil renders empty" do
    assert TimeFormat.iso8601(nil, "America/Los_Angeles") == ""
  end
end
