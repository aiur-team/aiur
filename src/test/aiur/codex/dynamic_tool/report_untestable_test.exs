defmodule Aiur.Codex.DynamicTool.ReportUntestableTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool.ReportUntestable

  test "reports the exact unverifiable criterion" do
    test_pid = self()

    response =
      ReportUntestable.execute(
        "report_untestable",
        %{"criterion" => "Read /dev/hidraw0", "reason" => "The sandbox has no HID device."},
        untestable_reporter: fn criterion, reason ->
          send(test_pid, {:reported, criterion, reason})
          :ok
        end
      )

    assert response["success"] == true
    assert_received {:reported, "Read /dev/hidraw0", "The sandbox has no HID device."}
  end

  test "rejects an incomplete report" do
    response = ReportUntestable.execute("report_untestable", %{"criterion" => "Press the dial"}, [])

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "reason"
  end
end
