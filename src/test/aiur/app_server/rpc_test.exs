defmodule Aiur.AppServer.RpcTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.Rpc

  describe "send_line/2" do
    test "writes Jason encoded bytes with a trailing newline" do
      port =
        Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [
          :binary,
          :exit_status,
          line: 64_000
        ])

      assert true = Rpc.send_line(port, %{"id" => 1, "method" => "ping"})
      assert_receive {^port, {:data, {:eol, line}}}, 1_000
      assert Jason.decode!(line) == %{"id" => 1, "method" => "ping"}

      Port.close(port)
    end

    test "raises ArgumentError on a closed port" do
      port =
        Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [
          :binary,
          :exit_status
        ])

      true = Port.close(port)

      assert_raise ArgumentError, fn ->
        Rpc.send_line(port, %{"id" => 1})
      end
    end
  end

  describe "with_timeout_response/5" do
    test "returns matching result response" do
      port = script_port(~s(printf '%s\\n' '{"id":42,"result":{"ok":true}}'))

      assert {:ok, %{"ok" => true}} = Rpc.with_timeout_response(port, 42, 1_000, "", "Test")
    end

    test "skips unrelated JSON and non-JSON lines" do
      command = """
      printf '%s\\n' '{"id":1,"result":{"skip":true}}'
      printf '%s\\n' 'warning: side output'
      printf '%s\\n' '{"id":42,"result":{"ok":true}}'
      """

      port = script_port(command)

      assert {:ok, %{"ok" => true}} = Rpc.with_timeout_response(port, 42, 1_000, "", "Test")
    end

    test "returns timeout and port exit errors" do
      idle_port = script_port("sleep 0.2")
      assert {:error, :response_timeout} = Rpc.with_timeout_response(idle_port, 42, 20, "", "Test")

      exit_port = script_port("exit 7")
      assert {:error, {:port_exit, 7}} = Rpc.with_timeout_response(exit_port, 42, 1_000, "", "Test")
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
