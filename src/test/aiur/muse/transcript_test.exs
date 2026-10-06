defmodule Aiur.Muse.TranscriptTest do
  use ExUnit.Case, async: true

  alias Aiur.Muse.Approvals
  alias Aiur.Muse.Transcript

  test "native item identity and turn identity survive rendering" do
    item = %{"kind" => "agentMessage", "itemId" => "message-1", "turnId" => "turn-1", "text" => "Native answer"}
    assert {:ok, event} = Transcript.extract(completed(item), "fallback-turn")
    assert %{role: :assistant, body: "Native answer", msg_id: "message-1", turn_id: "turn-1"} = event
    assert {:ok, repeated} = Transcript.extract(completed(item), "fallback-turn")
    assert repeated.msg_id == "message-1"
    assert :skip = Transcript.extract(completed(%{item | "text" => ""}), nil)
  end

  test "tool result preserves inputs, output and failure status under durable item identity" do
    item = %{
      "kind" => "toolCall",
      "itemId" => "native-item",
      "callId" => "provider-call",
      "tool" => "emit_alert",
      "args" => ~s({"name":"test"}),
      "visibleOutput" => "permission refused",
      "status" => "failed"
    }

    assert {:ok, %{role: :tool, msg_id: "native-item", payload: payload}} = Transcript.extract(completed(item), nil)
    assert payload.arguments == %{"name" => "test"}
    assert payload.output == "permission refused"
    assert payload.status == "failed"
  end

  test "reasoning and shell output use their own transcript roles" do
    assert {:ok, %{role: :reasoning, body: "Visible reasoning"}} =
             Transcript.extract(completed(%{"kind" => "reasoning", "text" => "Visible reasoning"}), nil)

    assert {:ok, %{role: :command, body: "pwd", payload: %{output: "/workspace", exit_code: 0}}} =
             Transcript.extract(completed(%{"kind" => "userShell", "commandText" => "pwd", "visibleOutput" => "/workspace", "exitCode" => 0}), nil)
  end

  test "unknown native item kinds remain visible without dumping the raw payload" do
    message = completed(%{"kind" => "futureKind", "itemId" => "future", "status" => "inProgress", "secret" => "hidden"})
    assert {:ok, event} = Transcript.extract(message, nil)
    assert event.body == "Muse futureKind (inProgress)"
    assert event.payload == %{native_kind: "futureKind", status: "inProgress"}
    refute inspect(event) =~ "hidden"
  end

  test "a text delta requires a known assistant item rather than mislabeling reasoning" do
    message = %{payload: %{"method" => "item/delta", "params" => %{"field" => "text", "itemId" => "m1", "delta" => "hello"}}}
    assert :skip = Transcript.extract(message, nil)

    assert {:ok, %{kind: :assistant_delta, body: "hello", id: "m1"}} =
             Transcript.extract(Map.put(message, :muse_item_kind, "agentMessage"), nil)

    assert :skip = Transcript.extract(Map.put(message, :muse_item_kind, "reasoning"), nil)
  end

  defp completed(item), do: %{payload: %{"method" => "item/completed", "params" => %{"item" => item}}}

  test "approval renders the native subject and only well-formed explicit choices" do
    requirement = %{"approvalId" => "approval-a", "sourceIndex" => 0}

    params = %{
      "approvalId" => "approval-a",
      "currentRequirementId" => requirement,
      "subject" => %{"kind" => "shell", "command" => "pwd"},
      "availableChoices" => [nil, %{"choiceId" => "once", "label" => "Allow once"}]
    }

    for method <- ["approval/request", "approval/requested", "approval/updated"] do
      message = %{payload: %{"method" => method, "params" => params}}
      assert {:ok, %{body: body}} = Transcript.extract(message, nil)
      assert body =~ "Muse needs approval for shell: pwd."
      assert body =~ "Allow once: /approve approval-a #{Approvals.requirement_token(requirement)} once"
      assert length(String.split(body, "/approve")) == 2
    end
  end
end
