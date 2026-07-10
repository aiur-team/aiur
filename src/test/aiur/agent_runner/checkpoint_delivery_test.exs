defmodule Aiur.AgentRunner.CheckpointDeliveryTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.CheckpointDelivery
  alias Aiur.Issue

  describe "operator_immediate_handler/2" do
    test "returns a zero-arity function" do
      issue = %Issue{identifier: "CD-01", id: "gid-cd01"}
      handler = CheckpointDelivery.operator_immediate_handler(issue, self())

      assert is_function(handler, 0)
    end
  end

  describe "safe_checkpoint_handler/2" do
    test "returns a one-arity function" do
      issue = %Issue{identifier: "CD-02", id: "gid-cd02"}
      handler = CheckpointDelivery.safe_checkpoint_handler(issue, self())

      assert is_function(handler, 1)
    end
  end
end
