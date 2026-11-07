defmodule Aiur.Application.ChildrenHeartbeatTest do
  use ExUnit.Case, async: false

  describe "heartbeat_metadata/0" do
    test "publishes a boolean executor_present from the executor roster" do
      %{"data" => data} = Aiur.Application.Children.heartbeat_metadata()

      assert is_boolean(data["executor_present"])
    end
  end
end
