defmodule Aiur.Codex.RpcTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.Rpc

  describe "startup_response_timeout_ms/1" do
    test "floors at thirty seconds without shortening larger timeouts" do
      assert Rpc.startup_response_timeout_ms(5_000) == 30_000
      assert Rpc.startup_response_timeout_ms(60_000) == 60_000
    end
  end

  describe "await_startup_response/2" do
    test "returns the matching result and skips unrelated JSON" do
      command = """
      printf '%s\\n' '{"id":1,"result":{"skip":true}}'
      printf '%s\\n' '{"id":42,"result":{"ok":true}}'
      """

      port = script_port(command)

      assert {:ok, %{"ok" => true}} = Rpc.await_startup_response(port, 42)
    end
  end

  describe "send_message/2" do
    test "writes a JSON line and raises on a closed port" do
      port = script_port("cat")

      assert true = Rpc.send_message(port, %{"id" => 1, "method" => "ping"})
      assert_receive {^port, {:data, {:eol, line}}}, 1_000
      assert Jason.decode!(line) == %{"id" => 1, "method" => "ping"}

      true = Port.close(port)

      assert_raise ArgumentError, fn ->
        Rpc.send_message(port, %{"id" => 2})
      end
    end
  end

  defp script_port(command) do
    Port.open({:spawn_executable, String.to_charlist(System.find_executable("bash"))}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: [~c"-lc", String.to_charlist(command)],
      line: 64_000
    ])
  end
end
