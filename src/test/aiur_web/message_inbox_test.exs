defmodule AiurWeb.MessageInboxTest do
  # A host app's chat attaches images to a message for a running worker; the
  # worker can only open what lands inside its own workspace.
  use ExUnit.Case, async: true

  alias AiurWeb.MessageInbox

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  setup do
    dir = Path.join(System.tmp_dir!(), "message-inbox-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end

  test "writes each attachment under the workspace inbox and names it in the message", %{workspace: workspace} do
    attachments = [image("mock.png"), image("mock.png")]

    assert {:ok, lines} = MessageInbox.write(workspace, "chat-1", attachments)
    assert lines == ["Attachment: .aiur/inbox/chat-1/mock.png", "Attachment: .aiur/inbox/chat-1/mock-1.png"]
    assert File.read!(Path.join(workspace, ".aiur/inbox/chat-1/mock.png")) == @png
    assert MessageInbox.append("Use this one ", lines) == "Use this one\n\n" <> Enum.join(lines, "\n")
  end

  test "a name cannot leave the inbox folder", %{workspace: workspace} do
    assert {:ok, ["Attachment: .aiur/inbox/_.._up/passwd"]} = MessageInbox.write(workspace, "/../up", [image("../../etc/passwd")])
    assert File.exists?(Path.join(workspace, ".aiur/inbox/_.._up/passwd"))
  end

  test "refuses types, data and counts outside Command media", %{workspace: workspace} do
    assert {:error, :unsupported_attachment_type} = MessageInbox.write(workspace, "m", [%{image("x.sh") | "mime_type" => "text/x-sh"}])
    assert {:error, :invalid_attachment_data} = MessageInbox.write(workspace, "m", [%{image("x.png") | "data" => "not base64!"}])
    assert {:error, :too_many_attachments} = MessageInbox.write(workspace, "m", List.duplicate(image("x.png"), 9))
    assert {:error, :workspace_unavailable} = MessageInbox.write(Path.join(workspace, "missing"), "m", [image("x.png")])
    assert File.ls!(workspace) == []
  end

  defp image(name), do: %{"name" => name, "mime_type" => "image/png", "data" => Base.encode64(@png)}
end
