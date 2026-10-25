defmodule Aiur.AppServer.RpcTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.AppServer.Rpc

  # Bound hangs without timing out successful fixtures during coverage startup.
  @script_response_timeout_ms 30_000

  describe "send_line/2" do
    test "writes Jason encoded bytes with a trailing newline" do
      port =
        Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [
          :binary,
          :exit_status,
          line: 64_000
        ])

      assert true = Rpc.send_line(port, %{"id" => 1, "method" => "ping"})
      assert_receive {^port, {:data, {:eol, line}}}, @script_response_timeout_ms
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

      assert {:ok, %{"ok" => true}} = Rpc.with_timeout_response(port, 42, @script_response_timeout_ms, "", "Test")
    end

    test "skips unrelated JSON and non-JSON lines" do
      command = """
      printf '%s\\n' '{"id":1,"result":{"skip":true}}'
      printf '%s\\n' 'warning: side output'
      printf '%s\\n' '{"id":42,"result":{"ok":true}}'
      """

      port = script_port(command)

      assert {:ok, %{"ok" => true}} = Rpc.with_timeout_response(port, 42, @script_response_timeout_ms, "", "Test")
    end

    test "routes a lifecycle notification that arrives before its awaited response" do
      command = """
      printf '%s\\n' '{"method":"account/updated","params":{"authMode":"chatgpt","email":"person@example.test"}}'
      printf '%s\\n' '{"id":42,"result":{"ok":true}}'
      """

      port = script_port(command)
      test_pid = self()

      handler = fn %{"method" => method, "params" => %{"authMode" => auth_mode}} ->
        send(test_pid, {:routed_lifecycle, method, auth_mode})
        :handled
      end

      assert {:ok, %{"ok" => true}} =
               Rpc.with_timeout_response(port, 42, @script_response_timeout_ms, "", "Test", handler)

      assert_receive {:routed_lifecycle, "account/updated", "chatgpt"}, @script_response_timeout_ms
    end

    test "returns timeout and port exit errors" do
      idle_port = script_port("cat >/dev/null")
      assert {:error, :response_timeout} = Rpc.with_timeout_response(idle_port, 42, 100, "", "Test")
      Port.close(idle_port)

      exit_port = script_port("exit 7")

      assert {:error, {:port_exit, 7}} =
               Rpc.with_timeout_response(exit_port, 42, @script_response_timeout_ms, "", "Test")
    end

    test "keeps an ordinary response after a missing sensitive response" do
      port = gated_script_port(~S|printf '%s\n' '{"id":6,"result":{"ok":true}}'|)
      on_exit(fn -> Rpc.clear_late_sensitive_responses(port) end)

      assert {:error, :response_timeout} =
               Rpc.with_timeout_response(port, 5, 100, "", "Test", fn _payload -> :ignore end, true)

      release_script_port(port)

      assert {:ok, %{"ok" => true}} = Rpc.with_timeout_response(port, 6, @script_response_timeout_ms, "", "Test")
    end

    test "quarantines malformed late sensitive output with its retained id" do
      secret = "person@example.test credential=super-secret"

      port =
        gated_script_port("""
        printf '%s\\n' '{"id":5,"result":{"account":"#{secret}"}'
        printf '%s\\n' '{"id":6,"result":{"ok":true}}'
        """)

      on_exit(fn -> Rpc.clear_late_sensitive_responses(port) end)

      assert {:error, :response_timeout} =
               Rpc.with_timeout_response(port, 5, 100, "", "Test", fn _payload -> :ignore end, true)

      release_script_port(port)

      assert {:ok, %{"ok" => true}} = Rpc.with_timeout_response(port, 6, @script_response_timeout_ms, "", "Test")
    end

    test "quarantines malformed late sensitive output with an escaped id key" do
      secret = "person@example.test credential=super-secret"

      port =
        gated_script_port("""
        printf '%s\\n' '{"\\u0069d":5,"result":{"account":"#{secret}"}} trailing'
        printf '%s\\n' '{"id":6,"result":{"ok":true}}'
        """)

      on_exit(fn -> Rpc.clear_late_sensitive_responses(port) end)

      assert {:error, :response_timeout} =
               Rpc.with_timeout_response(port, 5, 100, "", "Test", fn _payload -> :ignore end, true)

      release_script_port(port)

      log =
        capture_log(fn ->
          assert {:ok, %{"ok" => true}} = Rpc.with_timeout_response(port, 6, @script_response_timeout_ms, "", "Test")
        end)

      assert log =~ "Test sensitive response stream output redacted"
      refute log =~ secret
    end

    test "quarantines a sensitive response whose id arrived before its timeout" do
      secret = "person@example.test credential=super-secret"

      port =
        gated_script_port("""
        printf '%s\\n' '#{secret}"}}'
        printf '%s\\n' '{"id":6,"result":{"ok":true}}'
        """)

      on_exit(fn -> Rpc.clear_late_sensitive_responses(port) end)

      assert {:error, :response_timeout} =
               Rpc.with_timeout_response(port, 5, 100, ~s({"id":5,"result":{"account":"), "Test", fn _payload -> :ignore end, true)

      release_script_port(port)

      log =
        capture_log(fn ->
          assert {:ok, %{"ok" => true}} = Rpc.with_timeout_response(port, 6, @script_response_timeout_ms, "", "Test")
        end)

      assert log =~ "Test sensitive response stream output redacted"
      refute log =~ secret
    end

    test "quarantines malformed output without an id while a sensitive response is late" do
      secret = "person@example.test credential=super-secret"

      port =
        gated_script_port("""
        printf '%s\\n' '#{secret}'
        printf '%s\\n' '{"id":6,"result":{"ok":true}}'
        """)

      on_exit(fn -> Rpc.clear_late_sensitive_responses(port) end)

      assert {:error, :response_timeout} =
               Rpc.with_timeout_response(port, 5, 100, "", "Test", fn _payload -> :ignore end, true)

      release_script_port(port)

      log =
        capture_log(fn ->
          assert {:ok, %{"ok" => true}} = Rpc.with_timeout_response(port, 6, @script_response_timeout_ms, "", "Test")
        end)

      assert log =~ "Test sensitive response stream output redacted"
      refute log =~ secret
    end

    test "does not route a late sensitive response with a notification-shaped result" do
      secret = "person@example.test credential=super-secret"

      port =
        gated_script_port("""
        printf '%s\\n' '{"method":"account/updated","result":{"email":"#{secret}"}}'
        printf '%s\\n' '{"id":6,"result":{"ok":true}}'
        """)

      on_exit(fn -> Rpc.clear_late_sensitive_responses(port) end)
      test_pid = self()

      assert {:error, :response_timeout} =
               Rpc.with_timeout_response(port, 5, 100, "", "Test", fn _payload -> :ignore end, true)

      release_script_port(port)

      log =
        capture_log(fn ->
          assert {:ok, %{"ok" => true}} =
                   Rpc.with_timeout_response(port, 6, @script_response_timeout_ms, "", "Test", fn payload ->
                     send(test_pid, {:unexpected_notification, payload})
                     :handled
                   end)
        end)

      refute_receive {:unexpected_notification, _payload}, 100
      refute log =~ secret
    end

    test "quarantines a late sensitive response that also carries a method" do
      secret = "person@example.test credential=super-secret"

      port =
        gated_script_port("""
        printf '%s\\n' '{"id":5,"method":"server/response","result":{"account":"#{secret}"}}'
        printf '%s\\n' '{"id":6,"result":{"ok":true}}'
        """)

      on_exit(fn -> Rpc.clear_late_sensitive_responses(port) end)

      assert {:error, :response_timeout} =
               Rpc.with_timeout_response(port, 5, 100, "", "Test", fn _payload -> :ignore end, true)

      release_script_port(port)

      log =
        capture_log(fn ->
          assert {:ok, %{"ok" => true}} = Rpc.with_timeout_response(port, 6, @script_response_timeout_ms, "", "Test")
        end)

      refute log =~ secret
    end

    test "keeps an id-colliding request and unrelated malformed output after a sensitive timeout" do
      port =
        gated_script_port("""
        printf '%s\\n' '{"id":5,"method":"server/request","params":{}}'
        printf '%s\\n' 'ordinary non-json output'
        printf '%s\\n' '{"id":6,"result":{"ok":true}}'
        """)

      on_exit(fn -> Rpc.clear_late_sensitive_responses(port) end)
      test_pid = self()

      assert {:error, :response_timeout} =
               Rpc.with_timeout_response(port, 5, 100, "", "Test", fn _payload -> :ignore end, true)

      release_script_port(port)

      assert {:ok, %{"ok" => true}} =
               Rpc.with_timeout_response(port, 6, @script_response_timeout_ms, "", "Test", fn payload ->
                 send(test_pid, {:id_colliding_request, payload})
                 :handled
               end)

      assert_receive {:id_colliding_request, %{"id" => 5, "method" => "server/request"}}, @script_response_timeout_ms
    end
  end

  defp gated_script_port(command), do: script_port("IFS= read -r _\n" <> command)

  defp release_script_port(port), do: Port.command(port, "continue\n")

  defp script_port(command) do
    Port.open({:spawn_executable, String.to_charlist(System.find_executable("bash"))}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: [~c"-c", String.to_charlist(command)],
      line: 64_000
    ])
  end
end
