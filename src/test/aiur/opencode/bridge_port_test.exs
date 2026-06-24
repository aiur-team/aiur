defmodule Aiur.Opencode.BridgePortTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.BridgePort
  alias Aiur.Opencode.BridgeSupervisor

  @host "127.0.0.1"

  test "keeps an available default port" do
    {port, socket} = listen_on_loopback(0)
    :gen_tcp.close(socket)

    assert BridgePort.resolve(@host, {:default, port}) == {:ok, port}
  end

  test "selects a nearby free port when the default port is occupied" do
    {port, socket} = listen_on_loopback(0)

    try do
      assert {:ok, selected} = BridgePort.resolve(@host, {:default, port})
      assert selected > port
      assert selected <= port + 100
    after
      :gen_tcp.close(socket)
    end
  end

  test "does not auto-select when an env-pinned port is occupied" do
    {port, socket} = listen_on_loopback(0)

    try do
      assert {:error, message} = BridgePort.resolve(@host, {:env, port})
      assert message =~ "opencode bridge port #{port} is already in use"
      assert message =~ "AIUR_OPENCODE_BRIDGE_PORT=#{port + 1}"
      assert message =~ "currently pinned by AIUR_OPENCODE_BRIDGE_PORT"
    after
      :gen_tcp.close(socket)
    end
  end

  test "does not auto-select when a workflow-pinned port is occupied" do
    {port, socket} = listen_on_loopback(0)

    try do
      assert {:error, message} = BridgePort.resolve(@host, {:workflow, port})
      assert message =~ "opencode bridge port #{port} is already in use"
      assert message =~ "AIUR_OPENCODE_BRIDGE_PORT=#{port + 1}"
      assert message =~ "currently pinned by workflow opencode.bridge_port"
    after
      :gen_tcp.close(socket)
    end
  end

  test "passes port zero through to the listener" do
    assert BridgePort.resolve(@host, {:default, 0}) == {:ok, 0}
    assert BridgePort.resolve(@host, {:env, 0}) == {:ok, 0}
  end

  test "supervisor stores an auto-selected default port for later config reads" do
    previous_port_override = Application.get_env(:aiur, :opencode_bridge_port_override)
    Application.delete_env(:aiur, :opencode_bridge_port_override)
    {port, socket} = listen_on_loopback(0)

    try do
      selected = BridgeSupervisor.resolve_bridge_port!(@host, {:default, port})

      assert selected > port
      assert Application.get_env(:aiur, :opencode_bridge_port_override) == selected
    after
      :gen_tcp.close(socket)
      restore_app_env(:opencode_bridge_port_override, previous_port_override)
    end
  end

  defp listen_on_loopback(port) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, {:active, false}, ip: {127, 0, 0, 1}])
    {:ok, actual_port} = :inet.port(socket)
    {actual_port, socket}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
