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

  describe "start!/1 with an injected monitor function" do
    test "returns :ok when the monitor call succeeds" do
      assert :ok = Distribution.start!(fn _enable, _opts -> :ok end)
    end

    test "returns {:error, :not_distributed} when the monitor call raises" do
      raising = fn _enable, _opts -> raise ArgumentError, "no distribution" end
      assert {:error, :not_distributed} = Distribution.start!(raising)
    end
  end

  describe "node_name/1 with an injected Node.self/0" do
    test "returns the node name when distribution is active" do
      assert :"sym@127.0.0.1" =
               Distribution.node_name(fn -> :"sym@127.0.0.1" end)
    end

    test "returns nil when the BEAM is not distributed" do
      assert is_nil(Distribution.node_name(fn -> :nonode@nohost end))
    end
  end
end
