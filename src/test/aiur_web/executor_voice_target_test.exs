defmodule AiurWeb.ExecutorVoiceTargetTest do
  use ExUnit.Case, async: true
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.VoiceTargets
  @target %{kind: :executor, instance_id: "machine/run"}

  test "available and degraded Executor conversations accept dictation" do
    for state <- [:available, :degraded, "available", "degraded"] do
      assert :ok = validate(%{state: state})
    end
  end

  test "absent Executor is not found and unmanaged Executor is not writable" do
    assert {:error, %{reason_code: "target_not_found"}} = validate(%{state: :unavailable, reason: :executor_absent})
    assert {:error, %{reason_code: "target_not_writable"}} = validate(%{state: :unavailable, reason: :executor_not_managed})
    assert {:error, %{reason_code: "target_not_writable"}} = validate(%{state: :available, mode: %{effective: nil}})
  end

  test "unknown and malformed capability entries preserve unknown cause" do
    for entry <- [nil, %{}, %{state: :unknown}, %{state: :unknown, reason: :executor_absent}, %{state: :unavailable, reason: :timeout}, :bad] do
      assert {:error, %{reason_code: "unknown"}} = validate(entry)
    end
  end

  test "unavailable registry or missing instance identity is unknown" do
    for report_fun <- [fn -> raise "registry failed" end, fn -> exit(:timeout) end, fn -> %{} end] do
      EndpointStubs.put(capabilities_report_fun: report_fun)
      assert {:error, %{reason_code: "unknown"}} = VoiceTargets.validate(@target, "executor_composer")
    end
  end

  test "an Executor target must name this exact instance" do
    for instance <- [nil, "another/run"] do
      target = %{@target | instance_id: instance}
      EndpointStubs.put(capabilities_report_fun: fn -> report(%{state: :available}) end)
      assert {:error, %{reason_code: "target_not_found"}} = VoiceTargets.validate(target, "executor_composer")
    end
  end

  # Existing surface validation guard, not coverage of Executor availability.
  test "future regression guard: Executor targets are refused on worker surfaces before registry access" do
    EndpointStubs.put(capabilities_report_fun: fn -> flunk("registry read") end)
    assert {:error, %{reason_code: "invalid_payload"}} = VoiceTargets.validate(@target, "agent_composer")
  end

  defp validate(entry) do
    EndpointStubs.put(capabilities_report_fun: fn -> report(entry) end)
    VoiceTargets.validate(@target, "executor_composer")
  end

  defp report(entry), do: %{instance: %{instance_id: "machine/run"}, capabilities: %{"executor.conversation" => entry}}
end
