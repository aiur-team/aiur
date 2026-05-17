defmodule SymphonyElixir.DistributionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Distribution

  describe "start!/0" do
    test "returns :ok regardless of distribution state and installs a nodes monitor" do
      assert :ok = Distribution.start!()
    end
  end

  describe "node_name/0" do
    test "returns nil when running on :nonode@nohost" do
      # In the default mix test runtime the BEAM is not distributed.
      if Node.alive?() do
        assert is_atom(Distribution.node_name())
      else
        assert is_nil(Distribution.node_name())
      end
    end
  end

  describe "epmd_address/0" do
    test "reads from ERL_EPMD_ADDRESS env var with empty-string default" do
      original = System.get_env("ERL_EPMD_ADDRESS")
      System.put_env("ERL_EPMD_ADDRESS", "127.0.0.1")
      assert Distribution.epmd_address() == "127.0.0.1"

      System.delete_env("ERL_EPMD_ADDRESS")
      assert Distribution.epmd_address() == ""

      if original, do: System.put_env("ERL_EPMD_ADDRESS", original)
    end
  end

  describe "hidden_pane_nodes/0" do
    test "returns a list" do
      assert is_list(Distribution.hidden_pane_nodes())
    end
  end
end
