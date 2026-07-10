defmodule Aiur.Codex.OperatorDeliveryTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.OperatorDelivery

  describe "send_operator_message/2" do
    test "writes a turn/start frame with a fresh request id" do
      port = open_cat_port()

      session = %{
        port: port,
        thread_id: "thread-abc",
        workspace: "/tmp/workspace",
        approval_policy: "untrusted",
        turn_sandbox_policy: %{"mode" => "read-only"}
      }

      assert {:ok, request_id} =
               OperatorDelivery.send_operator_message(session, %{kind: :text, body: "hello agent"})

      assert is_integer(request_id) and request_id > 0

      frame = read_one_frame(port)
      assert frame["method"] == "turn/start"
      assert frame["id"] == request_id
      assert frame["params"]["threadId"] == "thread-abc"
      assert frame["params"]["input"] == [%{"type" => "text", "text" => "hello agent"}]
      assert frame["params"]["cwd"] == "/tmp/workspace"
      assert frame["params"]["approvalPolicy"] == "untrusted"
      assert frame["params"]["sandboxPolicy"] == %{"mode" => "read-only"}

      close_port(port)
    end

    test "returns {:error, :port_closed} when the port is dead" do
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
               OperatorDelivery.send_operator_message(session, %{kind: :text, body: "hello"})
    end

    test "returns {:error, :invalid_session} for malformed sessions" do
      assert {:error, :invalid_session} =
               OperatorDelivery.send_operator_message(%{}, %{kind: :text, body: "hello"})
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
