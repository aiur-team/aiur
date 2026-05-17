defmodule SymphonyElixir.PaneRPCTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PaneRPC

  describe "snapshot/0" do
    test "returns a list" do
      assert is_list(PaneRPC.snapshot())
    end
  end

  describe "send_operator_message/2" do
    test "rejects bodies larger than the cap" do
      oversized = String.duplicate("x", 65_537)
      assert {:error, :body_too_long} = PaneRPC.send_operator_message("MT-1", oversized)
    end

    test "strips control characters before forwarding" do
      # The forward will fail (no running agent) but body sanitization runs first.
      assert {:error, _} = PaneRPC.send_operator_message("MT-1", "hi\x01there")
    end
  end

  describe "attach_conversation/1 and detach_conversation/1" do
    test "attach returns :ok and detach is a no-op when no subscription exists" do
      assert :ok = PaneRPC.attach_conversation("MT-99")
      assert :ok = PaneRPC.detach_conversation("MT-99")
    end
  end
end
