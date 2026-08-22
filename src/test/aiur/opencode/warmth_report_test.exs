defmodule Aiur.Opencode.WarmthReportTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.WarmthReport

  test "computes loose→strict delta from an event stream" do
    events = [
      %{phase: :slot_attach_added, identifier: "issue-1", slot: 1, at_ms: 100},
      %{phase: :slot_visible_changed, identifier: "issue-1", slot: 1, at_ms: 110},
      %{phase: :slot_attach_added, identifier: "issue-2", slot: 1, at_ms: 200},
      %{phase: :slot_attach_added, identifier: "issue-2", slot: 2, at_ms: 350}
    ]

    rows = WarmthReport.from_events(events)
    issue_2 = Enum.find(rows, &(&1.identifier == "issue-2"))

    assert issue_2.t_first_attach_ms == 200
    assert issue_2.t_strict_ms == 350
    assert issue_2.loose_to_strict_delta_ms == 150
  end

  test "reports :strict_never_reached when attach_count never clears visible_count + 1" do
    events = [
      %{phase: :slot_attach_added, identifier: "issue-1", slot: 1, at_ms: 100},
      %{phase: :slot_visible_changed, identifier: "issue-1", slot: 1, at_ms: 110},
      %{phase: :slot_attach_added, identifier: "issue-2", slot: 1, at_ms: 200}
    ]

    rows = WarmthReport.from_events(events)
    issue_2 = Enum.find(rows, &(&1.identifier == "issue-2"))

    assert issue_2.t_first_attach_ms == 200
    assert issue_2.t_strict_ms == nil
    assert issue_2.loose_to_strict_delta_ms == :strict_never_reached
  end

  test "format/1 returns a non-empty string with the header" do
    events = [
      %{phase: :slot_attach_added, identifier: "issue-1", slot: 1, at_ms: 100}
    ]

    text = events |> WarmthReport.from_events() |> WarmthReport.format()

    assert text =~ "identifier"
    assert text =~ "issue-1"
    assert text =~ "100"
  end

  test "format/1 with empty rows reports nothing-found" do
    assert WarmthReport.format([]) =~ "no slot_attach_added events found"
  end

  test "parses aiur_perf lines from log content" do
    log = """
    some unrelated line
    aiur_perf phase=slot_attach_added at_ms=100 slot=1 identifier=issue-1
    aiur_perf phase=slot_visible_changed at_ms=110 slot=1 identifier=issue-1
    aiur_perf phase=slot_attach_added at_ms=150 slot=1 identifier=issue-2
    aiur_perf phase=slot_attach_added at_ms=300 slot=2 identifier=issue-2
    """

    path =
      Path.join(System.tmp_dir!(), "warmth_report_test_#{System.pid()}-#{System.unique_integer([:positive])}.log")

    File.write!(path, log)

    rows = WarmthReport.from_log_file(path)
    issue_2 = Enum.find(rows, &(&1.identifier == "issue-2"))

    assert issue_2.t_first_attach_ms == 150
    assert issue_2.t_strict_ms == 300
    assert issue_2.loose_to_strict_delta_ms == 150

    File.rm!(path)
  end
end
