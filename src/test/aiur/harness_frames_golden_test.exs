defmodule Aiur.HarnessFramesGoldenTest do
  use Aiur.TestSupport

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent
  alias Aiur.Muse.{CodingAgent, Protocol}

  @moduletag :r7_characterization
  @payload %{kind: :text, body: "Operator says: check \"frames\".\nThen continue — safely."}

  # Characterization guards for future provider moves; no production behavior changes here.
  setup do
    write_workflow_file!(Workflow.workflow_file_path(), claude_model: nil)
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, line: 64_000])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    {:ok, port: port}
  end

  test "claude headless operator message is a turn/start with threadId, input and cwd", %{port: port} do
    session = %{port: port, thread_id: "thread-golden", workspace: "/workspace/golden"}
    assert {:ok, id} = ClaudeAgent.send_operator_message(session, @payload)
    assert capture_frame(port, id) == fixture("claude_operator_turn_start")["without_model"]
  end

  test "claude headless operator message carries the session model when set", %{port: port} do
    session = %{port: port, thread_id: "thread-golden", workspace: "/workspace/golden", model: "session-model"}
    assert {:ok, id} = ClaudeAgent.send_operator_message(session, @payload)
    assert capture_frame(port, id) == fixture("claude_operator_turn_start")["with_model"]
  end

  test "muse operator message is a turn/start with ifBusy queue" do
    assert Protocol.turn_start_frame(1, "session-golden", @payload.body, if_busy: "queue", command_id: "command-golden") ==
             fixture("muse_operator_turn_start")
  end

  test "muse send_operator_message writes the golden frame to the transport", %{port: port} do
    assert {:ok, id} = CodingAgent.send_operator_message(%{port: port, thread_id: "session-golden"}, @payload)
    frame = capture_frame(port, id)
    assert Map.fetch!(frame["params"], "commandId") =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    assert put_in(frame, ["params", "commandId"], "command-golden") == fixture("muse_operator_turn_start")
  end

  test "muse rejects empty operator text", %{port: port} do
    assert {:error, :invalid_operator_message} =
             CodingAgent.send_operator_message(%{port: port, thread_id: "session-golden"}, %{kind: :text, body: ""})
  end

  defp capture_frame(port, id) do
    receive_barrier({^port, {:data, {:eol, line}}})
    assert %{"id" => ^id} = frame = Jason.decode!(line)
    Map.put(frame, "id", 1)
  end

  defp fixture(name) do
    Path.join([__DIR__, "..", "fixtures", "harness_frames", name <> ".json"])
    |> File.read!()
    |> Jason.decode!()
  end
end
