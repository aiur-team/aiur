defmodule Aiur.Opencode.ChatCompletionsTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.ChatCompletions

  test "build_chunk returns an OpenAI-compatible streaming envelope" do
    chunk = ChatCompletions.build_chunk("chatcmpl-test", %{content: "hello", finish_reason: nil})

    assert chunk.id == "chatcmpl-test"
    assert chunk.object == "chat.completion.chunk"
    assert [%{delta: %{content: "hello"}, finish_reason: nil}] = chunk.choices
  end

  test "build_chunk omits delta content for final chunks" do
    chunk = ChatCompletions.build_chunk("chatcmpl-test", %{content: nil, finish_reason: "stop"})

    assert [%{delta: %{}, finish_reason: "stop"}] = chunk.choices
  end
end
