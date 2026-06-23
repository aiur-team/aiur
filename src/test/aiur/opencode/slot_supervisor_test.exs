defmodule Aiur.Opencode.SlotSupervisorTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.SlotSupervisor

  describe "acquire_slot/0 with no registered slots" do
    test "returns :no_ready_slot" do
      assert SlotSupervisor.acquire_slot() == {:error, :no_ready_slot}
    end
  end

  describe "slot_count/0 with no registered slots" do
    test "returns zero" do
      assert SlotSupervisor.slot_count() == 0
    end
  end

  describe "acquire_slot_or_grow/0 with no registered slots" do
    test "returns :no_ready_slot (growth is best-effort, never the caller's result)" do
      assert SlotSupervisor.acquire_slot_or_grow() == {:error, :no_ready_slot}
    end
  end
end
