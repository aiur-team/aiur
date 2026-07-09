defmodule Aiur.AppServer.MessagesTest do
  use ExUnit.Case, async: true

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
