defmodule Aiur.Opencode.ChatCompletions.SseTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.ChatCompletions.Sse

  test "build_chunk returns an OpenAI-compatible streaming envelope" do
    chunk = Sse.build_chunk("chatcmpl-test", %{content: "hello", finish_reason: nil})

    assert chunk.id == "chatcmpl-test"
    assert chunk.object == "chat.completion.chunk"
    assert [%{delta: %{content: "hello"}, finish_reason: nil}] = chunk.choices
  end

  test "build_chunk omits delta content for final chunks" do
    chunk = Sse.build_chunk("chatcmpl-test", %{content: nil, finish_reason: "stop"})

    assert [%{delta: %{}, finish_reason: "stop"}] = chunk.choices
  end

  describe "finish_reason_for/1" do
    test ":input_required finishes with stop, not tool_calls" do
      # A "tool_calls" finish with no tool-call payload makes opencode
      # re-open the chat-completion request for the same unanswered
      # __aiur_turn__ marker, busy-looping until the ActiveTurns entry
      # expires (~60s) and pegging the TUI. "stop" ends the turn so the
      # agent resumes via a fresh marker after the dashboard approval.
      assert Sse.finish_reason_for(:input_required) == "stop"
      refute Sse.finish_reason_for(:input_required) == "tool_calls"
    end

    test "failed and done reasons also finish with stop" do
      assert Sse.finish_reason_for({:failed, :boom}) == "stop"
      assert Sse.finish_reason_for(:done) == "stop"
    end
  end
end
