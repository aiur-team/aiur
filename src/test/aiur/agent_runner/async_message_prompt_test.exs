defmodule Aiur.AgentRunner.AsyncMessagePromptTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.TurnPrompt
  alias Aiur.Issue

  test "async effective mode adds read guidance with unread count on every turn path" do
    for {turn, opts} <- [{1, []}, {1, [resumed: true]}, {1, [prior_work: true]}, {2, []}] do
      prompt = prompt({:ok, %{effective: :async, unread_count: 3}}, turn, opts)
      assert prompt =~ "Messages from the operator are held rather than shown automatically."
      assert prompt =~ "Call `aiur_read_messages` at natural pauses and before finishing."
      assert prompt =~ "3 unread"
      assert prompt =~ "Before concluding that no further work remains or handing back, read and act on every pending operator message."
    end
  end

  test "sync, steer and unknown modes add no guidance even with unread messages" do
    for result <- [
          {:ok, %{effective: :sync, unread_count: 3}},
          {:ok, %{effective: :steer, unread_count: 3}},
          {:ok, %{effective: nil, unread_count: 3}},
          {:error, :unavailable}
        ] do
      refute prompt(result) =~ "aiur_read_messages"
    end
  end

  test "zero and unavailable counts retain guidance without claiming unread messages" do
    for count <- [0, nil] do
      rendered = prompt({:ok, %{effective: :async, unread_count: count}})
      assert rendered =~ "Call `aiur_read_messages` at natural pauses and before finishing."
      refute rendered =~ " unread"
    end
  end

  test "mode and count are refreshed for the next turn" do
    assert prompt({:ok, %{effective: :async, unread_count: 2}}) =~ "2 unread"
    assert prompt({:ok, %{effective: :async, unread_count: 1}}, 2) =~ "1 unread"
    refute prompt({:ok, %{effective: :sync, unread_count: 1}}, 3) =~ "aiur_read_messages"
  end

  defp prompt(result, turn \\ 1, opts \\ []) do
    reader = fn identifier ->
      assert identifier == "6502"
      result
    end

    TurnPrompt.build_turn_prompt(issue(), opts ++ [spec_status: :ok, listener_prompt_reader: reader], turn, nil)
  end

  defp issue, do: %Issue{id: "internal-6502", identifier: "6502", title: "Prompt guidance", state: "in-progress"}
end
