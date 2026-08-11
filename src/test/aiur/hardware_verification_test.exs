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

  test "keeps a physical step when a criterion also documents its result" do
    issue = %Issue{description: "## Acceptance\n- Unplug the device and document the result in the runbook."}

    assert [%{signal: :physical_action}] = HardwareVerification.matched_criteria(issue)
    assert HardwareVerification.required?(issue)
  end

  test "does not route documentation that only describes a physical action" do
    issue = %Issue{description: "## Acceptance\n- Document how to unplug the device in the runbook."}

    assert [] = HardwareVerification.matched_criteria(issue)
    refute HardwareVerification.required?(issue)
  end

  test "does not route negated, mock, emulator, or documentation criteria" do
    issue = %Issue{
      description: "## Acceptance\n- Do not use sudo.\n- Verify mock systemctl behavior.\n- Test /dev/hidraw0 with an emulator.\n- Update docs to remove sudo."
    }

    assert [] = HardwareVerification.matched_criteria(issue)
    refute HardwareVerification.required?(issue)
  end

  test "routes real spike sequence criteria while ignoring only their negated clauses" do
    issue = %Issue{
      description: """
      ## Spike sequence
      1. **udev + enumeration.** Install udev rules, physically unplug/replug, and confirm /dev/hidraw0 enumerates.
      2. Do not use sudo, but press the dial on the physical device and record the event.
      3. Test mock systemctl behavior without touching a device.
      """
    }

    signals = HardwareVerification.detected_signals(issue)

    assert :udev in signals
    assert :device_path in signals
    assert :physical_action in signals
    refute :privileged_operation in signals
    refute :system_service in signals
  end

  test "detects the hardware go/no-go in the #1342 spike format" do
    issue = %Issue{
      description: """
      ## Spike sequence
      1. **udev + enumeration.** Reload, physically unplug/replug, and run the HID example.
      2. **Input + output round-trip — the go/no-go.** Log rotate / down / up events and write a full-width LCD image.
      3. **Suspend/resume.** `systemctl suspend`, resume, and verify the heartbeat recovers.

      ## Sub-check

      Can the hidraw backend send feature reports on the current kernel?
      """
    }

    assert HardwareVerification.required?(issue)
    assert :udev in HardwareVerification.detected_signals(issue)
    assert :physical_action in HardwareVerification.detected_signals(issue)
    assert :system_service in HardwareVerification.detected_signals(issue)
  end

  test "keeps physical work in a mixed mock-and-device criterion" do
    issue = %Issue{
      description: "## Acceptance\n- Exercise a mock /dev/hidraw0 while physically replugging the device.\n- Verify a mock systemctl path while physically pressing the dial."
    }

    assert [:physical_action, :physical_action] =
             issue |> HardwareVerification.matched_criteria() |> Enum.map(& &1.signal)
  end

  test "evaluates mixed and negated clauses independently" do
    issue = %Issue{
      description: """
      ## Acceptance
      - Mock /dev/hidraw0 and press the dial.
      - Do not use sudo and press the dial.
      - Remove sudo from docs and run unit tests.
      """
    }

    assert [:physical_action, :physical_action] =
             issue |> HardwareVerification.matched_criteria() |> Enum.map(& &1.signal)
  end

  test "evaluates physical signals independently from nearby mock and negation context" do
    issue = %Issue{
      description: """
      ## Acceptance
      - Without sudo, press the dial.
      - Use a mock transport before physically replugging the real device.
      - Verify the app does not invoke sudo.
      - Unit tests reject /dev/hidraw0 paths.
      - Ensure no systemctl command is executed.
      """
    }

    assert [:physical_action, :physical_action] =
             issue |> HardwareVerification.matched_criteria() |> Enum.map(& &1.signal)
  end

  test "does not let a negated privileged signal suppress physical work in the same segment" do
    issue = %Issue{description: "## Acceptance\n- Replug the physical device without sudo."}

    assert [:physical_action] =
             issue |> HardwareVerification.matched_criteria() |> Enum.map(& &1.signal)
  end

  test "does not route ordinary unit-test coverage of a physical-action handler" do
    issue = %Issue{description: "## Acceptance\n- Add unit tests for the press the dial handler."}

    assert [] = HardwareVerification.matched_criteria(issue)
  end

  test "does not route a locally negated physical action" do
    issue = %Issue{description: "## Acceptance\n- The operator must not press the dial."}

    assert [] = HardwareVerification.matched_criteria(issue)
  end

  test "does not route a factual absence of privileged access" do
    issue = %Issue{description: "## Acceptance\n- Verify that sudo is not available in the sandbox."}

    assert [] == HardwareVerification.matched_criteria(issue)
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

  test "fails closed when an operator leaves conflicting outcomes on a spike" do
    issue = %{
      "body" => "## Acceptance\n- Verify /dev/hidraw0.",
      "labels" => [
        %{"name" => "agent:operator-verified"},
        %{"name" => "agent:operator-verification-passed"},
        %{"name" => "agent:operator-verification-no-go"}
      ]
    }

    assert nil == HardwareVerification.outcome_label(issue, "agent")
    refute HardwareVerification.dependency_resolved?(issue, "agent")

    assert {:error, {:operator_signoff_required, _detail}} =
             HardwareVerification.verify_terminal_transition(issue, "cancelled", "agent")
  end

  test "requires authenticated evidence before a passing blocker releases dependents" do
    issue = %{
      "body" => "## Acceptance\n- Verify /dev/hidraw0.",
      "labels" => [
        %{"name" => "agent:operator-verified"},
        %{"name" => "agent:operator-verification-passed"}
      ]
    }

    refute HardwareVerification.dependency_resolved?(issue, "agent")
    assert HardwareVerification.dependency_resolved?(Map.put(issue, :operator_signoff_valid?, true), "agent")
  end

  test "invalidates every stale operator outcome before recording a new untestable report" do
    test_pid = self()

    assert :ok =
             HardwareVerification.invalidate_operator_signoff("1483", "agent", fn issue_id, label ->
               send(test_pid, {:removed, issue_id, label})
               :ok
             end)

    assert_received {:removed, "1483", "agent:operator-verified"}
    assert_received {:removed, "1483", "agent:operator-verification-passed"}
    assert_received {:removed, "1483", "agent:operator-verification-no-go"}
  end
end
