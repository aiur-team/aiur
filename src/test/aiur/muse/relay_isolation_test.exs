defmodule Aiur.Muse.RelayIsolationTest do
  use Aiur.TestSupport

  test "native MSP keeps a direct Port when app-server relays default on" do
    assert Aiur.Config.settings!().agent.relay
    assert {:ok, port} = Aiur.Muse.Transport.start(File.cwd!(), "exec cat")

    try do
      assert is_port(port)
      assert :ok = Aiur.Muse.Transport.send_frame(port, %{"jsonrpc" => "2.0", "id" => 1})
      assert {:ok, %{"jsonrpc" => "2.0", "id" => 1}} = Aiur.Muse.Transport.receive_frame(port, 2_000)
    after
      Aiur.Muse.Transport.stop(port)
    end
  end
end
