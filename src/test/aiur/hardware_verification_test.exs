defmodule Aiur.HardwareVerificationTest do
  use ExUnit.Case, async: true

  alias Aiur.{HardwareVerification, Issue}

  test "detects device paths, privileged operations, and physical actions" do
    assert [:device_path] = HardwareVerification.detected_signals("Read /dev/hidraw0 and confirm output.")
    assert :privileged_operation in HardwareVerification.detected_signals("Run sudo systemctl restart device.service")
    assert [:physical_action] = HardwareVerification.detected_signals("Unplug and replug the controller, then press the dial.")
  end

  test "detects criteria from an issue title and description" do
    issue = %Issue{title: "HID transport", description: "Verify /dev/bus/usb access after a replug."}

    assert HardwareVerification.required?(issue)
    assert :device_path in HardwareVerification.detected_signals(issue)
    assert :physical_action in HardwareVerification.detected_signals(issue)
  end

  test "requires explicit operator sign-off before a detected ticket can finish" do
    issue = %{
      "body" => "Run sudo udevadm trigger and verify the physical device.",
      "labels" => [%{"name" => "agent:operator-verification-required"}]
    }

    assert {:error, {:operator_signoff_required, detail}} =
             HardwareVerification.verify_terminal_transition(issue, "done", "agent")

    assert detail.required_label == "agent:operator-verification-required"
    assert detail.verified_label == "agent:operator-verified"

    signed_off = put_in(issue, ["labels"], [%{"name" => "agent:operator-verified"}])
    assert :ok = HardwareVerification.verify_terminal_transition(signed_off, "done", "agent")
  end

  test "does not impose a sign-off requirement for ordinary tickets" do
    assert :ok = HardwareVerification.verify_terminal_transition(%{"body" => "Add unit tests.", "labels" => []}, "done", "agent")
  end

  test "requires sign-off before cancelled terminal states too" do
    issue = %{"body" => "Use /dev/ttyUSB0 for verification.", "labels" => []}

    assert {:error, {:operator_signoff_required, _detail}} =
             HardwareVerification.verify_terminal_transition(issue, "cancelled", "agent")
  end
end
