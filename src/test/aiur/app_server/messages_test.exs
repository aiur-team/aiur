defmodule Aiur.AppServer.MessagesTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Aiur.AppServer.Messages

  test "emit_message/4 builds an event envelope with metadata and timestamp" do
    parent = self()

    Messages.emit_message(
      fn message -> send(parent, {:message, message}) end,
      :tool_result,
      %{details: "ok"},
      %{session_id: "s1"}
    )

    assert_receive {:message, message}
    assert message.event == :tool_result
    assert message.details == "ok"
    assert message.session_id == "s1"
    assert %DateTime{} = message.timestamp
  end

  test "normalize_tool_result/1 lifts first text content item into output" do
    assert Messages.normalize_tool_result(%{"contentItems" => [%{"text" => "done"}]})["output"] == "done"

    assert Messages.normalize_tool_result(%{"output" => "kept", "contentItems" => [%{"text" => "ignored"}]})[
             "output"
           ] == "kept"
  end

  test "normalize_tool_result/2 spills successful output over 100 KiB", %{tmp_dir: tmp_dir} do
    output = String.duplicate("x", 100 * 1024 + 1)

    result =
      Messages.normalize_tool_result(
        %{"success" => true, "output" => output, "contentItems" => [%{"text" => output}]},
        tmp_dir
      )

    assert result["success"]
    assert result["output"] == hd(result["contentItems"])["text"]
    assert [path] = Regex.run(~r/saved to (.+)\. Read the file/, result["output"], capture: :all_but_first)
    assert String.starts_with?(path, Path.expand(tmp_dir))
    assert File.read!(path) == output
  end

  test "normalize_tool_result/2 keeps boundary-sized and failed output inline", %{tmp_dir: tmp_dir} do
    boundary = String.duplicate("x", 100 * 1024)
    failed = %{"success" => false, "output" => boundary <> "x"}

    assert Messages.normalize_tool_result(%{"success" => true, "output" => boundary}, tmp_dir)["output"] == boundary
    assert Messages.normalize_tool_result(failed, tmp_dir) == failed
  end

  test "normalize_tool_result/2 bounds the response when spilling fails", %{tmp_dir: tmp_dir} do
    blocked_workspace = Path.join(tmp_dir, "not-a-directory")
    File.write!(blocked_workspace, "file")
    output = String.duplicate("x", 100 * 1024 + 1)

    result = Messages.normalize_tool_result(%{"success" => true, "output" => output}, blocked_workspace)

    refute result["success"]
    assert result["output"] =~ "could not be saved"
    assert byte_size(result["output"]) < 1024
    refute result["output"] =~ output
  end

  test "tool call helpers normalize blank names and missing arguments" do
    assert Messages.tool_call_name(%{"tool" => " emit_alert "}) == "emit_alert"
    assert Messages.tool_call_name(%{name: " "}) == nil
    assert Messages.tool_call_name(nil) == nil
    assert Messages.tool_call_arguments(%{"arguments" => %{"a" => 1}}) == %{"a" => 1}
    assert Messages.tool_call_arguments(%{}) == %{}
  end

  test "initialize_frame/0 contains the shared app-server handshake" do
    frame = Messages.initialize_frame()

    assert frame["id"] == 1
    assert frame["method"] == "initialize"
    assert frame["params"]["capabilities"]["experimentalApi"] == true
    assert frame["params"]["clientInfo"]["name"] == "aiur-orchestrator"
    assert is_binary(frame["params"]["clientInfo"]["version"])
    assert Messages.initialized_frame() == %{"method" => "initialized", "params" => %{}}
  end
end
