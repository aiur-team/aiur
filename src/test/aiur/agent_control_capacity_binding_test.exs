defmodule Aiur.AgentControlCapacityBindingTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.Orchestrator.CapacityBinding
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  # Future regression guard: both surfaces must classify one daemon report alike.
  test "status and Analytics agree when the AIMD envelope binds" do
    capacity = %{
      occupied: 9,
      max: 20,
      effective: 9,
      configured: 16,
      available: 0,
      queued_demand?: true,
      session_override?: true,
      active: 9,
      reserved_paused: 0,
      capacity_hold: nil
    }

    binding_label = CapacityBinding.binding(capacity) |> CapacityBinding.short_label()

    snapshot = %{
      statuses: [],
      capacity: capacity,
      polling: %{},
      global_pause: %{globally_paused: false, paused_at: nil, source: nil}
    }

    output = capture_io(fn -> AgentControlCLI.status(fleet_view: {:ok, snapshot, %{status: :current}}) end)
    assert output =~ "AGENTS 9/20 (binding: AIMD envelope, effective cap=9)"

    assert Presenter.cap_label(%{
             cap: 9,
             cap_available?: true,
             configured_cap: 16,
             session_cap: 20,
             cap_binding: binding_label
           }) == "9 cap (binding: AIMD envelope, session 20, configured 16)"
  end
end
