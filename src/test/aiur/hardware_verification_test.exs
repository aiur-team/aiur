defmodule Aiur.HardwareVerificationTest do
  use ExUnit.Case, async: true

  alias Aiur.{HardwareVerification, Issue}

  test "detects device paths, privileged operations, and physical actions" do
    assert [:device_path] = HardwareVerification.detected_signals("## Acceptance\n- Read /dev/hidraw0 and confirm output.")
    assert :privileged_operation in HardwareVerification.detected_signals("## Acceptance\n- Run sudo systemctl restart device.service")
    assert [:physical_action] = HardwareVerification.detected_signals("## Acceptance\n- Unplug and replug the controller, then press the dial.")
  end

  test "returns structured evidence from acceptance criteria" do
    issue = %Issue{title: "HID transport", description: "## Acceptance\n- Verify /dev/bus/usb access after a replug."}

    assert HardwareVerification.required?(issue)
    assert :device_path in HardwareVerification.detected_signals(issue)
    assert :physical_action in HardwareVerification.detected_signals(issue)

    assert [%{signal: :device_path, evidence: "- Verify /dev/bus/usb access after a replug.", operator_action: "Verify this criterion on the physical device."}, %{signal: :physical_action}] =
             HardwareVerification.matched_criteria(issue)
  end

  test "does not route docs, mocks, or emulators as physical criteria" do
    issue = %Issue{title: "HID docs", description: "## Acceptance\n- Add an emulator for /dev/hidraw.\n- Remove sudo from docs.\n- Mock systemctl."}

    assert [] = HardwareVerification.matched_criteria(issue)
    refute HardwareVerification.required?(issue)
  end

  test "requires explicit operator sign-off before a detected ticket can finish" do
    issue = %{
      "body" => "## Acceptance\n- Run sudo udevadm trigger and verify the physical device.",
      "labels" => [%{"name" => "agent:operator-verification-required"}]
    }

    assert {:error, {:operator_signoff_required, detail}} =
             HardwareVerification.verify_terminal_transition(issue, "done", "agent")

    assert detail.required_label == "agent:operator-verification-required"
    assert detail.verified_label == "agent:operator-verified"

    signed_off = put_in(issue, ["labels"], [%{"name" => "agent:operator-verified"}, %{"name" => "agent:operator-verification-passed"}])
    assert :ok = HardwareVerification.verify_terminal_transition(signed_off, "done", "agent")
  end

  test "does not impose a sign-off requirement for ordinary tickets" do
    assert :ok = HardwareVerification.verify_terminal_transition(%{"body" => "Add unit tests.", "labels" => []}, "done", "agent")
  end

  test "requires sign-off before cancelled terminal states too" do
    issue = %{"body" => "## Acceptance\n- Use /dev/ttyUSB0 for verification.", "labels" => []}

    assert {:error, {:operator_signoff_required, _detail}} =
             HardwareVerification.verify_terminal_transition(issue, "cancelled", "agent")
  end

  test "allows an operator no-go only when cancelling the spike" do
    issue = %{"body" => "## Acceptance\n- Verify /dev/hidraw0.", "labels" => [%{"name" => "agent:operator-verified"}, %{"name" => "agent:operator-verification-no-go"}]}

    assert :ok = HardwareVerification.verify_terminal_transition(issue, "cancelled", "agent")
    assert {:error, {:operator_no_go_requires_cancellation, _}} = HardwareVerification.verify_terminal_transition(issue, "done", "agent")
    refute HardwareVerification.dependency_resolved?(issue, "agent")
  end
end
