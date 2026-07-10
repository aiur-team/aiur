defmodule Aiur.Opencode.ChatCompletions.SseTest.ClosedAdapter do
  # Stub adapter whose chunk/2 simulates a disconnected client.
  def chunk(state, _data), do: {:error, {:closed, state}}
end

defmodule Aiur.Opencode.ChatCompletions.SseTest do
  use ExUnit.Case, async: true

  import Plug.Test

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

  describe "chunk/4" do
    test "returns conn unchanged when the underlying adapter reports closed" do
      # Simulates an opencode client that disconnected mid-stream. The
      # caller's receive loop must continue draining the mailbox so it can
      # finalize on :aiur_turn_done; crashing the handler here would kill
      # the whole codex turn rendering.
      alias Aiur.Opencode.ChatCompletions.SseTest.ClosedAdapter
      sent_conn = conn(:post, "/") |> Plug.Conn.send_chunked(200)
      closed_conn = %{sent_conn | adapter: {ClosedAdapter, :state}}

      result = Sse.chunk(closed_conn, "chatcmpl-test", "hello", nil)

      assert result == closed_conn
    end
  end
end
