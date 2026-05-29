defmodule Aiur.CodingAgentTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Codex.CodingAgent, as: CodexAgent

  describe "send_operator_message/2" do
    test "Codex adapter writes a turn/start frame with a fresh request id" do
      port = open_cat_port()

      session = %{
        port: port,
        thread_id: "thread-abc",
        workspace: "/tmp/workspace",
        approval_policy: "untrusted",
        turn_sandbox_policy: %{"mode" => "read-only"}
      }

      assert {:ok, request_id} =
               CodexAgent.send_operator_message(session, %{kind: :text, body: "hello agent"})

      assert is_integer(request_id) and request_id > 0

      frame = read_one_frame(port)
      assert frame["method"] == "turn/start"
      assert frame["id"] == request_id
      assert frame["params"]["threadId"] == "thread-abc"
      assert frame["params"]["input"] == [%{"type" => "text", "text" => "hello agent"}]
      assert frame["params"]["cwd"] == "/tmp/workspace"
      assert frame["params"]["approvalPolicy"] == "untrusted"

      close_port(port)
    end

    test "Codex adapter returns {:error, :invalid_session} for malformed session" do
      assert {:error, :invalid_session} =
               CodexAgent.send_operator_message(%{}, %{kind: :text, body: "hi"})
    end

    test "Codex adapter returns {:error, :port_closed} when port is dead" do
      port = open_cat_port()
      close_port(port)

      session = %{
        port: port,
        thread_id: "thread-abc",
        workspace: "/tmp/workspace",
        approval_policy: "untrusted",
        turn_sandbox_policy: %{}
      }

      assert {:error, :port_closed} =
               CodexAgent.send_operator_message(session, %{kind: :text, body: "hi"})
    end

    test "Claude adapter writes a turn/start frame with a fresh request id" do
      port = open_cat_port()

      session = %{
        port: port,
        thread_id: "thread-xyz",
        workspace: "/tmp/workspace"
      }

      assert {:ok, request_id} =
               ClaudeAgent.send_operator_message(session, %{kind: :text, body: "hello claude"})

      assert is_integer(request_id) and request_id > 0

      frame = read_one_frame(port)
      assert frame["method"] == "turn/start"
      assert frame["id"] == request_id
      assert frame["params"]["threadId"] == "thread-xyz"
      assert frame["params"]["input"] == [%{"type" => "text", "text" => "hello claude"}]

      close_port(port)
    end

    test "Claude adapter returns {:error, :invalid_session} for malformed session" do
      assert {:error, :invalid_session} =
               ClaudeAgent.send_operator_message(%{}, %{kind: :text, body: "hi"})
    end
  end

  describe "unretryable codex error detection" do
    test "willRetry:false inside params trips the unretryable path" do
      payload = %{"method" => "error", "params" => %{"willRetry" => false, "message" => "usageLimitExceeded"}}
      assert CodexAgent.unretryable_codex_error_for_test(payload)
      assert CodexAgent.codex_error_reason_for_test(payload, "error") == "error: usageLimitExceeded"
    end

    test "willRetry:false at the notification root also trips it" do
      assert CodexAgent.unretryable_codex_error_for_test(%{"willRetry" => false})
    end

    test "snake_case will_retry:false is honored" do
      assert CodexAgent.unretryable_codex_error_for_test(%{"params" => %{"will_retry" => false}})
    end

    test "willRetry:true is retryable (continues, not a hard failure)" do
      refute CodexAgent.unretryable_codex_error_for_test(%{"params" => %{"willRetry" => true}})
    end

    test "absent willRetry is retryable" do
      refute CodexAgent.unretryable_codex_error_for_test(%{"params" => %{"message" => "transient blip"}})
    end

    test "reason falls back to the method when no detail field is present" do
      assert CodexAgent.codex_error_reason_for_test(%{"params" => %{"willRetry" => false}}, "task/error") == "task/error"
    end
  end

  defp open_cat_port do
    Port.open(
      {:spawn_executable, System.find_executable("cat") |> String.to_charlist()},
      [:binary, :exit_status, {:line, 64_000}]
    )
  end

  defp read_one_frame(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        Jason.decode!(line)

      {^port, {:data, line}} when is_binary(line) ->
        line
        |> String.trim_trailing()
        |> Jason.decode!()
    after
      1_000 -> flunk("no frame read from port within 1s")
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
