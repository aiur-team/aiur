defmodule Aiur.Codex.HandshakeTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.{Frames, Handshake}

  @policies %{approval_policy: "never", thread_sandbox: "read-only"}

  describe "resume_outcome/2" do
    test "classifies resumed, fresh, and fallback outcomes" do
      assert Handshake.resume_outcome({:ok, "thr_1"}, "thr_1") == {:resumed, "thr_1"}
      assert Handshake.resume_outcome({:ok, "thr_2"}, "thr_1") == {:fresh, "thr_2"}
      assert Handshake.resume_outcome({:error, :response_timeout}, "thr_1") == {:fallback, :response_timeout}
    end
  end

  describe "parse_thread_response/1" do
    test "extracts valid thread ids, rejects invalid payloads, and passes through errors" do
      assert Handshake.parse_thread_response({:ok, %{"thread" => %{"id" => "thr"}}}) == {:ok, "thr"}

      assert Handshake.parse_thread_response({:ok, %{"thread" => %{"name" => "missing"}}}) ==
               {:error, {:invalid_thread_payload, %{"name" => "missing"}}}

      assert Handshake.parse_thread_response({:error, :response_timeout}) == {:error, :response_timeout}
    end
  end

  describe "read_rate_limits/1" do
    test "requests and returns account rate-limit windows" do
      port =
        script_port("""
        while IFS= read -r line; do
          case "$line" in
            *'\"id\":4'*) printf '%s\\n' '{"id":4,"result":{"rateLimits":{"primary":{"usedPercent":100,"resetsAt":123}}}}'; exit 0 ;;
          esac
        done
        """)

      assert {:ok, %{"primary" => %{"usedPercent" => 100, "resetsAt" => 123}}} = Handshake.read_rate_limits(port)
    end

    test "returns an error for a malformed account response" do
      port =
        script_port("""
        while IFS= read -r line; do
          case "$line" in
            *'\"id\":4'*) printf '%s\\n' '{"id":4,"result":{"unexpected":true}}'; exit 0 ;;
          esac
        done
        """)

      assert {:error, {:invalid_rate_limits_payload, %{"unexpected" => true}}} = Handshake.read_rate_limits(port)
    end
  end

  describe "trusted account/read startup protocol" do
    test "reads an already-authenticated binding from the real account/read frame" do
      port =
        script_port("""
        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*) printf '%s\\n' '{"id":1,"result":{"codexHome":"/home/codex"}}' ;;
            *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1"}}}' ;;
            *'"id":5'*) printf '%s\\n' '{"id":5,"result":{"requiresOpenaiAuth":true,"account":{"type":"chatgpt","email":"person@example.test","planType":"plus"}}}'; exit 0 ;;
          esac
        done
        """)

      assert {:ok, "thread-1", false, true} = Handshake.establish_with_rate_limits(port, "/ws", @policies, nil)

      assert {:ok, %{"requiresOpenaiAuth" => true, "account" => %{"type" => "chatgpt"}}} =
               Handshake.read_account(port)
    end

    test "routes trusted notifications that arrive while thread startup waits" do
      port =
        script_port("""
        while IFS= read -r line; do
          case "$line" in
            *'"id":2'*)
              printf '%s\\n' '{"method":"account/updated","params":{"authMode":"chatgpt","email":"person@example.test"}}'
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1"}}}'
              exit 0 ;;
          esac
        done
        """)

      test_pid = self()

      handler = fn %{"method" => method} ->
        send(test_pid, {:startup_lifecycle, method})
        :handled
      end

      assert {:ok, "thread-1"} =
               Handshake.send_thread_init(port, Frames.thread_init_frame(nil, "/ws", @policies), on_notification: handler)

      assert_receive {:startup_lifecycle, "account/updated"}
    end

    test "routes trusted notifications that arrive while turn startup waits" do
      port =
        script_port("""
        while IFS= read -r line; do
          case "$line" in
            *'"id":3'*)
              printf '%s\\n' '{"method":"account/updated","params":{"authMode":"chatgpt","email":"person@example.test"}}'
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
              exit 0 ;;
          esac
        done
        """)

      test_pid = self()

      handler = fn %{"method" => method} ->
        send(test_pid, {:turn_lifecycle, method})
        :handled
      end

      session = %{
        port: port,
        thread_id: "thread-1",
        workspace: "/ws",
        approval_policy: "never",
        turn_sandbox_policy: %{},
        account_generation_notification_handler: handler
      }

      assert {:ok, "turn-1"} = Handshake.start_turn(session, "prompt", %{identifier: "DASH-018", title: "test"})
      assert_receive {:turn_lifecycle, "account/updated"}
    end
  end

  describe "closed-port degradation" do
    test "send_thread_init/2 returns port_closed" do
      port = open_cat_port()
      true = Port.close(port)

      assert {:error, :port_closed} =
               Handshake.send_thread_init(port, Frames.thread_init_frame("thr_1", "/ws", @policies))
    end

    test "send_initialize/1 returns port_closed" do
      port = open_cat_port()
      true = Port.close(port)

      assert {:error, :port_closed} = Handshake.send_initialize(port)
    end
  end

  test "establish/4 treats a different resumed thread id as a clean start" do
    port =
      script_port("""
      while IFS= read -r line; do
        case "$line" in
          *'\"id\":1'*) printf '%s\\n' '{"id":1,"result":{"ok":true}}' ;;
          *'\"method\":\"thread/resume\"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"fresh-thread"}}}'; exit 0 ;;
        esac
      done
      """)

    assert {:ok, "fresh-thread", false} = Handshake.establish(port, "/ws", @policies, "stale-thread")
  end

  test "establish_with_rate_limits/4 enables the probe for a Codex initialize response" do
    port =
      script_port("""
      while IFS= read -r line; do
        case "$line" in
          *'\"id\":1'*) printf '%s\\n' '{"id":1,"result":{"codexHome":"/home/codex","platformFamily":"unix","platformOs":"linux","userAgent":"codex"}}' ;;
          *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1"}}}'; exit 0 ;;
        esac
      done
      """)

    assert {:ok, "thread-1", false, true} = Handshake.establish_with_rate_limits(port, "/ws", @policies, nil)
  end

  defp open_cat_port do
    Port.open({:spawn_executable, String.to_charlist(System.find_executable("cat"))}, [
      :binary,
      :exit_status
    ])
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
