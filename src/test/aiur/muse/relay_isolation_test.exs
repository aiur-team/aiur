defmodule Aiur.Muse.RelayIsolationTest do
  use Aiur.TestSupport

  alias Aiur.Config
  alias Aiur.Muse.Transport

  test "native MSP keeps a direct Port when app-server relays default on" do
    assert Config.settings!().agent.relay
    assert {:ok, port} = Transport.start(File.cwd!(), "exec cat")

    try do
      assert is_port(port)
      assert :ok = Transport.send_frame(port, %{"jsonrpc" => "2.0", "id" => 1})
      assert {:ok, %{"jsonrpc" => "2.0", "id" => 1}} = Transport.receive_frame(port, 2_000)
    after
      Transport.stop(port)
    end
  end
end
