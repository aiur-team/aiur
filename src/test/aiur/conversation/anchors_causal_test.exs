defmodule Aiur.Conversation.AnchorsCausalTest do
  use ExUnit.Case, async: true
  alias Aiur.Conversation.{Anchors, Entry}

  setup do
    now = DateTime.utc_now()
    event = %{event_id: 1, topic: "ticket.1.branch.push", kind: "push", conversation_id: "conv", observed_at: now, payload: %{sha: "abcdef1234567890", ref: "refs/heads/feature"}}
    command = %Entry{kind: "command", pos: 1, session_seq: 1, body: "git push origin feature", output: "1234567..abcdef1 feature -> feature", observed_at: now, meta: %{exit_code: 0}}
    %{event: event, command: command, now: now}
  end

  test "push range end matches event sha, including force push; wrong sha never matches", ctx do
    assert_causal(ctx.event, ctx.command)
    assert_causal(ctx.event, %{ctx.command | output: "+1234567...abcdef1 feature -> feature (forced update)"})
    assert :none = Anchors.causal(ctx.event, [%{ctx.command | output: "1234567..7654321 feature -> feature"}])
    assert :none = Anchors.causal(ctx.event, [%{ctx.command | body: "git status"}])
  end

  test "new branch requires the destination branch name", ctx do
    command = %{ctx.command | output: " * [new branch] HEAD -> feature\n"}
    assert_causal(ctx.event, command)
    assert :none = Anchors.causal(ctx.event, [%{command | output: " * [new branch] feature -> other\n"}])
  end

  test "create matches the output PR URL number", ctx do
    event = %{ctx.event | kind: "pr_opened", payload: %{"pr" => %{"number" => 42}}}
    command = %{ctx.command | body: "gh pr create --draft", output: "https://github.com/aiur-team/aiur/pull/42\n"}
    assert_causal(event, command)
    assert :none = Anchors.causal(event, [%{command | output: "https://github.com/aiur-team/aiur/pull/43"}])
    assert :none = Anchors.causal(event, [%{command | body: "gh pr view 42"}])
  end

  test "merge requires a number in the command or an output URL, including webhook payload", ctx do
    event = %{ctx.event | kind: "pr_merged", payload: %{"pull_request" => %{"number" => 42}}}
    command = %{ctx.command | body: "gh pr merge #42 --squash", output: "Merged"}
    assert_causal(event, command)
    assert_causal(event, %{command | body: "gh pr merge", output: "https://github.com/aiur-team/aiur/pull/42"})
    assert :none = Anchors.causal(event, [%{command | body: "gh pr merge", output: "Merged current branch"}])
    assert :none = Anchors.causal(event, [%{command | body: "gh pr merge 43"}])
  end

  test "only exit zero commands are causal", ctx do
    assert_causal(ctx.event, ctx.command)
    for code <- [1, nil, "0"], do: assert(:none = Anchors.causal(ctx.event, [%{ctx.command | meta: %{exit_code: code}}]))
  end

  test "ten minute observation window is inclusive and excludes future commands", ctx do
    assert_causal(ctx.event, %{ctx.command | observed_at: DateTime.add(ctx.now, -600)})

    for seconds <- [-601, 1] do
      assert :none = Anchors.causal(ctx.event, [%{ctx.command | observed_at: DateTime.add(ctx.now, seconds)}])
    end

    assert :none = Anchors.causal(%{ctx.event | observed_at: nil}, [ctx.command])
  end

  test "latest position wins regardless of list ordering", ctx do
    assert {:ok, %{"pos" => 9}} = Anchors.causal(ctx.event, [%{ctx.command | pos: 9}, ctx.command, %{ctx.command | pos: 5}])
  end

  test "Claude disk Bash command joins successful tool result by original tool id", ctx do
    [command, result] = claude_entries(ctx, false)
    assert command.refs.tool_call_id == "call-1"
    assert result.refs.tool_call_id == "call-1"
    assert command.refs.provider_msg_id != result.refs.provider_msg_id
    assert {:ok, %{"pos" => 1, "precision" => "causal"}} = Anchors.causal(ctx.event, [command, result])
    assert :none = Anchors.causal(ctx.event, [command, %{result | refs: %{tool_call_id: "other"}}])
    assert :none = Anchors.causal(ctx.event, [command, %{result | session_seq: 2}])
    assert :none = Anchors.causal(ctx.event, [command, %{result | observed_at: DateTime.add(ctx.now, 1)}])
    assert :none = Anchors.causal(ctx.event, [command, %{result | meta: %{success: nil}}])
    assert :none = Anchors.causal(ctx.event, claude_entries(ctx, true))
  end

  test "Claude live notifications preserve call provenance and result errors", ctx do
    entries =
      for {item, pos} <- [
            {%{"type" => "tool_call", "id" => "command-item", "tool_use_id" => "call-1", "name" => "Bash", "input" => %{"command" => "git push"}}, 1},
            {%{"type" => "tool_result", "id" => "result-item", "tool_use_id" => "call-1", "content" => ctx.command.output, "is_error" => false}, 2}
          ] do
        {:ok, event} = Aiur.Claude.Transcript.extract(%{payload: %{"method" => "item/created", "params" => %{"item" => item}}}, nil)
        {:ok, entry} = Entry.from_transcript_event(event)
        %{entry | pos: pos, session_seq: 1, observed_at: ctx.now}
      end

    assert {:ok, %{"pos" => 1, "precision" => "causal"}} = Anchors.causal(ctx.event, entries)
    [command, result] = entries
    assert :none = Anchors.causal(ctx.event, [command, %{result | meta: %{success: false}}])
  end

  defp claude_entries(ctx, error) do
    for {role, id, block, pos} <- [
          {"assistant", "record-1", %{"type" => "tool_use", "id" => "call-1", "name" => "Bash", "input" => %{"command" => "git push"}}, 1},
          {"user", "record-2", %{"type" => "tool_result", "tool_use_id" => "call-1", "content" => ctx.command.output, "is_error" => error}, 2}
        ] do
      [event] = Aiur.Claude.Transcript.extract_disk_record(%{"type" => role, "uuid" => id, "message" => %{"content" => [block]}}, nil)
      {:ok, entry} = Entry.from_transcript_event(event)
      %{entry | pos: pos, session_seq: 1, observed_at: ctx.now}
    end
  end

  defp assert_causal(event, command) do
    assert {:ok, anchor} = Anchors.causal(event, [command])
    assert {anchor["pos"], anchor["placement"], anchor["precision"], anchor["method"]} == {command.pos, "at", "causal", "command_text"}
  end
end
